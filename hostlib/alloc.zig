//! Allocator (PLAN.md 6e: a port of research/alloc/versions/v7.zig, without its research switches).
//! Units: 4 KB, max 128 MB (u16 indexes). Tables per unit, outside the units.
//! Free units: a bitmap (to find the lowest free unit) and lists of free runs by length.
//! Small blocks (<= 2048 B): one size class and one task per 4 KB page, at the lowest
//! free unit. No header: the page tables give the class and the task. An empty page
//! goes back at once, to a reserve of at most 256 pages that only small pages use.
//! Other blocks: their own run of units, best fit, at the top end of the run. A block
//! that a realloc moves goes to the low end of a run of 2x its size, so that the next
//! realloc can grow it in place.
//! JS blocks (`js_alloc`) are in their own pages, with an owner word for `adopt`.
//! Live data never moves: Roc values and saved stacks hold raw addresses.

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const cpu = @import("cpu.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
const CH_SHIFT = 12;
const CH: usize = 1 << CH_SHIFT;
const MAX_UNITS: usize = (128 << 20) >> CH_SHIFT;
const SMALL_MAX: usize = 2048;

pub var OWNER: usize = 0;

// ---------------------------------------------------------------- units

const KIND_NONE: u8 = 0; // free, or below the pool
const KIND_SMALL: u8 = 1;
const KIND_LARGE: u8 = 2; // the first unit of a large block
const KIND_BODY: u8 = 3; // the other units of a large block
const KIND_FOREIGN: u8 = 4;
var U_KIND: [MAX_UNITS]u8 = @splat(0);
/// Small page or large block: the task slot.
var U_SLOT: [MAX_UNITS]u8 = @splat(0);
/// Large block or free run (at its first unit): the length in units.
var U_UNITS: [MAX_UNITS]u16 = @splat(0);
/// Free run (at its last unit): its first unit.
var U_START: [MAX_UNITS]u16 = @splat(0);
/// Small pages and large blocks: the task's lists. Free runs: the lists of the index.
var U_NEXT: [MAX_UNITS]u16 = @splat(0);
var U_PREV: [MAX_UNITS]u16 = @splat(0);
/// Large block: the requested end (the sum and a moving realloc stop there).
var U_HW: [MAX_UNITS]u32 = @splat(0);
// Small pages: one size class each, with their own free list and live count.
var U_CLASS: [MAX_UNITS]u8 = @splat(0);
var U_LIVE: [MAX_UNITS]u16 = @splat(0);
var U_BUMP: [MAX_UNITS]u16 = @splat(0);
/// Offset + 1 of the first free block in the page, 0 when none.
var U_FREE: [MAX_UNITS]u16 = @splat(0);
/// Pages of a task and class that can have room (doubly linked). The head is the current page.
var U_ANEXT: [MAX_UNITS]u16 = @splat(0);
var U_APREV: [MAX_UNITS]u16 = @splat(0);
var U_INAV: [MAX_UNITS]u8 = @splat(0);

var FREE_BITS: [MAX_UNITS / 64]u64 = @splat(0);
/// No free unit in the bitmap words below this one.
var LOW_HINT: usize = 0;
var POOL_LO: usize = 0;
var POOL_HI: usize = 0;
/// The memory end after our last grow: memory above it was grown by other code.
var GROWN_END: usize = 0;
pub var CHUNKS_USED: usize = 0;
/// Grow step in units. 4b makes it the shim option `growStepBytes`.
const GROW_CHUNKS: usize = PAGE >> CH_SHIFT;

/// Empty small pages go to a stack that only small pages use (no bitmap, no joins).
const CACHE_MAX: usize = 256;
var CACHE: [CACHE_MAX]u16 = @splat(0);
var CACHED: usize = 0;
fn smallGive(h: usize) void {
    if (CACHED < CACHE_MAX) {
        U_KIND[h] = KIND_NONE;
        CACHE[CACHED] = @intCast(h);
        CACHED += 1;
    } else runGive(h, 1);
}
/// Give all reserved pages back to the pool (they join their free neighbors).
/// Only when memory cannot grow. False when the reserve is empty.
fn cacheDrain() bool {
    if (CACHED == 0) return false;
    while (CACHED > 0) {
        CACHED -= 1;
        runGive(CACHE[CACHED], 1);
    }
    return true;
}

inline fn isFree(i: usize) bool {
    return (FREE_BITS[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}

/// Set the bitmap bits of units [first, first + n) to free or used.
fn setRange(first: usize, n: usize, free: bool) void {
    var i = first;
    const end_ = first + n;
    while (i < end_) {
        const w = i >> 6;
        const lo: u6 = @intCast(i & 63);
        const cnt = @min(64 - @as(usize, lo), end_ - i);
        const ones: u64 = if (cnt == 64) ~@as(u64, 0) else ((@as(u64, 1) << @intCast(cnt)) - 1);
        const mask = ones << lo;
        if (free) FREE_BITS[w] |= mask else FREE_BITS[w] &= ~mask;
        i += cnt;
    }
    if (free and (first >> 6) < LOW_HINT) LOW_HINT = first >> 6;
}

// ---------------------------------------------------------------- index of free runs

/// Lists by length: lengths below 8 exact, then 8 lists per power of 2.
const RL_FL = 14;
const RL_SL = 8;
var RL_HEAD: [RL_FL][RL_SL]u16 = std.mem.zeroes([RL_FL][RL_SL]u16);
var RL_FLBITS: u16 = 0;
var RL_SLBITS: [RL_FL]u8 = @splat(0);

inline fn rmap(len: usize) struct { fl: usize, sl: usize } {
    if (len < 8) return .{ .fl = 0, .sl = len };
    const l2: usize = std.math.log2_int(usize, len);
    return .{ .fl = l2 - 2, .sl = (len >> @intCast(l2 - 3)) & 7 };
}

fn runInsert(s: usize, len: usize) void {
    U_UNITS[s] = @intCast(len);
    U_START[s + len - 1] = @intCast(s);
    const m = rmap(len);
    const head = RL_HEAD[m.fl][m.sl];
    U_NEXT[s] = head;
    U_PREV[s] = 0;
    if (head != 0) U_PREV[head] = @intCast(s);
    RL_HEAD[m.fl][m.sl] = @intCast(s);
    RL_FLBITS |= @as(u16, 1) << @intCast(m.fl);
    RL_SLBITS[m.fl] |= @as(u8, 1) << @intCast(m.sl);
}

fn runRemove(s: usize) void {
    const m = rmap(U_UNITS[s]);
    const n = U_NEXT[s];
    const p = U_PREV[s];
    if (p != 0) U_NEXT[p] = n else RL_HEAD[m.fl][m.sl] = n;
    if (n != 0) U_PREV[n] = p;
    if (RL_HEAD[m.fl][m.sl] == 0) {
        RL_SLBITS[m.fl] &= ~(@as(u8, 1) << @intCast(m.sl));
        if (RL_SLBITS[m.fl] == 0) RL_FLBITS &= ~(@as(u16, 1) << @intCast(m.fl));
    }
}

/// A free run of at least `n` units: the shortest in the list of `n` (a short
/// walk), else the first run of the next list that is not empty. 0 when none.
fn runFind(n: usize) usize {
    if (n > MAX_UNITS) return 0;
    const m = rmap(n);
    var best: usize = 0;
    var r: usize = RL_HEAD[m.fl][m.sl];
    var k: u32 = 0;
    while (r != 0 and k < 8) : (k += 1) {
        if (U_UNITS[r] >= n and (best == 0 or U_UNITS[r] < U_UNITS[best])) best = r;
        r = U_NEXT[r];
    }
    if (best != 0) return best;
    var fl = m.fl;
    var sl_map: u32 = if (m.sl + 1 >= RL_SL) 0 else RL_SLBITS[fl] & (~@as(u32, 0) << @intCast(m.sl + 1));
    if (sl_map == 0) {
        const fl_map: u32 = if (fl + 1 >= RL_FL) 0 else RL_FLBITS & (~@as(u32, 0) << @intCast(fl + 1));
        if (fl_map == 0) return 0;
        fl = @ctz(fl_map);
        sl_map = RL_SLBITS[fl];
    }
    return RL_HEAD[fl][@ctz(sl_map)];
}

/// Take `n` units of the free run at `s`: its low end (`low`) or its top end.
fn runTake(s: usize, n: usize, low: bool) usize {
    const len: usize = U_UNITS[s];
    runRemove(s);
    const first = if (low) s else s + len - n;
    if (len > n) runInsert(if (low) s + n else s, len - n);
    setRange(first, n, false);
    CHUNKS_USED += n;
    return first;
}

/// Free units [s, s + n): join with the free runs on both sides.
fn runGive(s0: usize, n0: usize) void {
    var s = s0;
    var n = n0;
    CHUNKS_USED -= n;
    @memset(U_KIND[s .. s + n], KIND_NONE);
    setRange(s, n, true);
    if (s > POOL_LO and isFree(s - 1)) {
        const ls: usize = U_START[s - 1];
        runRemove(ls);
        n += s - ls;
        s = ls;
    }
    if (s + n < POOL_HI and isFree(s + n)) {
        const rn: usize = U_UNITS[s + n];
        runRemove(s + n);
        n += rn;
    }
    runInsert(s, n);
}

// ---------------------------------------------------------------- pool

fn poolInit() void {
    if (POOL_HI != 0) return;
    GROWN_END = @wasmMemorySize(0) * PAGE;
    POOL_LO = alignUp(GROWN_END, CH) >> CH_SHIFT;
    POOL_HI = POOL_LO;
}

/// Grow memory so that the free run at the top has `n` units. False on out-of-memory.
/// The only place that grows memory. 4b: ask JS first (`js_grow`).
fn poolGrow(n: usize) bool {
    poolInit();
    const top = @wasmMemorySize(0) * PAGE;
    // Other code (Roc's boxy runtime) grew memory: those units are not ours.
    if (top > GROWN_END) {
        const hi = alignUp(top, CH) >> CH_SHIFT;
        @memset(U_KIND[POOL_HI..hi], KIND_FOREIGN);
        POOL_HI = hi;
        GROWN_END = top;
    }
    const have: usize = if (POOL_HI > POOL_LO and isFree(POOL_HI - 1)) POOL_HI - U_START[POOL_HI - 1] else 0;
    const want = @max(n -| have, GROW_CHUNKS);
    const pages = (want * CH + PAGE - 1) / PAGE;
    if (POOL_HI + pages * (PAGE / CH) > MAX_UNITS) return false;
    if (@wasmMemoryGrow(0, pages) < 0) return false;
    GROWN_END = @wasmMemorySize(0) * PAGE;
    const hi = GROWN_END >> CH_SHIFT;
    const old_hi = POOL_HI;
    POOL_HI = hi;
    // As a give of the new units (it joins the top run), without the count.
    CHUNKS_USED += hi - old_hi;
    runGive(old_hi, hi - old_hi);
    return true;
}

/// The lowest free unit, for a small page. 0 on out-of-memory.
fn takeLow() usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        var w = @max(POOL_LO >> 6, LOW_HINT);
        while (w < (POOL_HI + 63) >> 6) : (w += 1) {
            const bits = FREE_BITS[w];
            if (bits == 0) {
                if (LOW_HINT == w) LOW_HINT = w + 1;
                continue;
            }
            // The lowest free unit starts its run: runs are always joined.
            return runTake((w << 6) + @ctz(bits), 1, true);
        }
        if (!poolGrow(1)) return 0;
    }
    return 0;
}

/// `n` units for a large block. `grow`: a realloc moves it, so it goes to the
/// low end of a run of 2n units if there is one. 0 on out-of-memory.
fn takeRun(n: usize, grow: bool) usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 3) : (tries += 1) {
        if (grow) {
            const r = runFind(n * 2);
            if (r != 0 and U_UNITS[r] >= n) return runTake(r, n, true);
        }
        const r = runFind(n);
        if (r != 0) return runTake(r, n, grow);
        // Out of memory: the pages of the reserve can join into a run of `n`.
        if (!poolGrow(n)) {
            if (cacheDrain()) continue;
            return 0;
        }
    }
    return 0;
}

// ---------------------------------------------------------------- tasks

const CLASSES = [13]usize{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048 };
const NCLASS = CLASSES.len;
const CLASS_UP: [SMALL_MAX / 16]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [SMALL_MAX / 16]u8 = undefined;
    for (0..SMALL_MAX / 16) |s| {
        var c = 0;
        while (CLASSES[c] < (s + 1) * 16) c += 1;
        t[s] = c;
    }
    break :blk t;
};
/// ceil(2^32 / size): the block index of an offset in the page is (off * RECIP) >> 32.
const RECIP: [NCLASS]u64 = blk: {
    var t: [NCLASS]u64 = undefined;
    for (CLASSES, 0..) |c, i| t[i] = ((1 << 32) + @as(u64, c) - 1) / c;
    break :blk t;
};

const Task = extern struct {
    owner: usize,
    slot: u32,
    small_head: u32, // all small pages (U_NEXT, U_PREV)
    large_head: u32, // all large blocks (U_NEXT, U_PREV)
    avail: [NCLASS]u16, // per class: the pages that can have room (U_ANEXT, U_APREV)
    _pad: [48 - 16 - 2 * NCLASS]u8,
};
comptime {
    std.debug.assert(@sizeOf(Task) % 16 == 0);
}
const MAX_TASKS = 256;
/// The slot of JS blocks (`js_alloc`): they have an owner word for `adopt`.
const JS_SLOT = MAX_TASKS - 1;
/// Slots for tasks: all but the host slot (0) and the JS slot.
pub const TASK_SLOTS: u32 = JS_SLOT - 1;
var TASKS: [MAX_TASKS]Task align(16) = blk: {
    var t = std.mem.zeroes([MAX_TASKS]Task);
    // JS pages carry the JS slot, so `adopt` and `freeAdopted` find them.
    t[JS_SLOT].slot = JS_SLOT;
    break :blk t;
};
/// SLOT_OWNER[i]: the task in slot i, 0 when the slot is free. Slot 0 is the host.
var SLOT_OWNER: [MAX_TASKS]usize = blk: {
    var t: [MAX_TASKS]usize = @splat(0);
    t[JS_SLOT] = std.math.maxInt(usize);
    break :blk t;
};
var LAST_OWNER: usize = 0;
var LAST_SLOT: usize = 0;

/// The record of `owner`, made on first use.
fn taskOf(owner: usize) *Task {
    if (owner == 0) return &TASKS[0];
    if (owner == LAST_OWNER) return &TASKS[LAST_SLOT];
    var free_slot: usize = 0;
    for (1..JS_SLOT) |i| {
        if (SLOT_OWNER[i] == owner) {
            LAST_OWNER = owner;
            LAST_SLOT = i;
            return &TASKS[i];
        }
        if (SLOT_OWNER[i] == 0 and free_slot == 0) free_slot = i;
    }
    if (free_slot == 0) mem.trap();
    const t = &TASKS[free_slot];
    t.* = std.mem.zeroes(Task);
    t.owner = owner;
    t.slot = @intCast(free_slot);
    SLOT_OWNER[free_slot] = owner;
    LAST_OWNER = owner;
    LAST_SLOT = free_slot;
    return t;
}

fn taskFind(owner: usize) ?*Task {
    if (owner == 0) return &TASKS[0];
    if (owner == LAST_OWNER) return &TASKS[LAST_SLOT];
    for (1..JS_SLOT) |i| if (SLOT_OWNER[i] == owner) return &TASKS[i];
    return null;
}

inline fn listPush(head: *u32, i: usize) void {
    U_NEXT[i] = @intCast(head.*);
    U_PREV[i] = 0;
    if (head.* != 0) U_PREV[head.*] = @intCast(i);
    head.* = @intCast(i);
}

inline fn listRemove(head: *u32, i: usize) void {
    const n = U_NEXT[i];
    const p = U_PREV[i];
    if (p != 0) U_NEXT[p] = n else head.* = n;
    if (n != 0) U_PREV[n] = p;
}

// ---------------------------------------------------------------- small pages

fn availPush(t: *Task, h: usize) void {
    const class = U_CLASS[h];
    const head = t.avail[class];
    U_ANEXT[h] = head;
    U_APREV[h] = 0;
    if (head != 0) U_APREV[head] = @intCast(h);
    t.avail[class] = @intCast(h);
    U_INAV[h] = 1;
}

fn availRemove(t: *Task, h: usize) void {
    const n = U_ANEXT[h];
    const p = U_APREV[h];
    if (p != 0) U_ANEXT[p] = n else t.avail[U_CLASS[h]] = n;
    if (n != 0) U_APREV[n] = p;
    U_INAV[h] = 0;
}

fn smallAlloc(t: *Task, class: usize) usize {
    const size = CLASSES[class];
    while (true) {
        const h: usize = t.avail[class];
        if (h == 0) break;
        const f: usize = U_FREE[h];
        if (f != 0) {
            const p = (h << CH_SHIFT) + f - 1;
            U_FREE[h] = @truncate(rdUsize(p + 4));
            wrUsize(p, 0);
            U_LIVE[h] += 1;
            return p;
        }
        const b: usize = U_BUMP[h];
        if (b + size <= CH) {
            U_BUMP[h] = @intCast(b + size);
            U_LIVE[h] += 1;
            // A page used before can hold an old FREE_MARK here.
            wrUsize((h << CH_SHIFT) + b, 0);
            return (h << CH_SHIFT) + b;
        }
        // Full: it leaves the list until a block in it is freed.
        availRemove(t, h);
    }
    const h = if (CACHED > 0) blk: {
        CACHED -= 1;
        break :blk CACHE[CACHED];
    } else takeLow();
    if (h == 0) return 0;
    U_KIND[h] = KIND_SMALL;
    U_SLOT[h] = @intCast(t.slot);
    U_CLASS[h] = @intCast(class);
    U_LIVE[h] = 1;
    U_BUMP[h] = @intCast(size);
    U_FREE[h] = 0;
    listPush(&t.small_head, h);
    availPush(t, h);
    wrUsize(h << CH_SHIFT, 0);
    return h << CH_SHIFT;
}

/// Word 0 of a free small block. The host sets a random value at start
/// (as glibc's tcache key), so live data matches it only by chance; a match is
/// then checked on the page's free list, so a live block is never kept.
var FREE_MARK: usize = 0xF4EE_B10C;
/// JS sets a random mark for each instance.
export fn set_free_mark(k: usize) void {
    mem.enter();
    if (k != 0) FREE_MARK = k;
}
pub var DOUBLE_FREES: u32 = 0;
export fn double_frees() u32 {
    return DOUBLE_FREES;
}
/// True when the block at `p` is on its page's free list. At most one step per slot.
fn onFreeList(h: usize, p: usize) bool {
    const base = h << CH_SHIFT;
    var f: usize = U_FREE[h];
    var steps = CH / CLASSES[U_CLASS[h]];
    while (f != 0 and steps > 0) : (steps -= 1) {
        if (base + f - 1 == p) return true;
        f = rdUsize(base + f - 1 + 4) & (CH - 1);
    }
    return false;
}
inline fn isLink(h: usize, link: usize) bool {
    if (link == 0) return true;
    if (link > U_BUMP[h]) return false;
    const off = link - 1;
    return ((off * RECIP[U_CLASS[h]]) >> 32) * CLASSES[U_CLASS[h]] == off;
}

/// The start of the small block that holds `ptr`.
inline fn smallStart(ptr: usize) usize {
    const base = ptr & ~(CH - 1);
    const idx: usize = @intCast(((ptr - base) * RECIP[U_CLASS[ptr >> CH_SHIFT]]) >> 32);
    return base + idx * CLASSES[U_CLASS[ptr >> CH_SHIFT]];
}

/// Free the small block at `p` (its start). An empty page goes back at once.
fn smallFree(t: *Task, p: usize) void {
    const h = p >> CH_SHIFT;
    // A second free of the block: the mark is there, the link is a block offset + 1
    // (or 0), and the block is on the free list.
    if (rdUsize(p) == FREE_MARK and isLink(h, rdUsize(p + 4))) {
        if (onFreeList(h, p)) {
            DOUBLE_FREES += 1;
            return;
        }
    }
    // The mark is not an owner, so a free block of a JS page has none.
    wrUsize(p, FREE_MARK);
    wrUsize(p + 4, U_FREE[h]);
    U_FREE[h] = @intCast(p - (h << CH_SHIFT) + 1);
    U_LIVE[h] -= 1;
    if (U_INAV[h] == 0) availPush(t, h);
    if (U_LIVE[h] == 0) {
        availRemove(t, h);
        listRemove(&t.small_head, h);
        smallGive(h);
    }
}

// ---------------------------------------------------------------- large blocks

fn largeAlloc(t: *Task, len: usize, grow: bool) usize {
    const n = (len + CH - 1) >> CH_SHIFT;
    const s = takeRun(n, grow);
    if (s == 0) return 0;
    U_KIND[s] = KIND_LARGE;
    if (n > 1) @memset(U_KIND[s + 1 .. s + n], KIND_BODY);
    U_SLOT[s] = @intCast(t.slot);
    U_UNITS[s] = @intCast(n);
    U_HW[s] = @intCast(len);
    listPush(&t.large_head, s);
    return s << CH_SHIFT;
}

fn largeFree(t: *Task, s: usize) void {
    listRemove(&t.large_head, s);
    U_HW[s] = 0;
    runGive(s, U_UNITS[s]);
}

/// Grow the large block at unit `s` in place to `m` units: take the low end of the free run after it.
fn largeGrowInPlace(s: usize, m: usize, at_top: bool) bool {
    const n: usize = U_UNITS[s];
    const e = s + n;
    if (at_top) {
        // The block, or the free run after it, ends at the pool top: grow memory.
        const room: usize = if (e < POOL_HI and isFree(e)) U_UNITS[e] else 0;
        if (e + room != POOL_HI) return false;
        if (room < m - n and !poolGrow(m - n)) return false;
    }
    if (e >= POOL_HI or !isFree(e) or U_UNITS[e] < m - n) return false;
    _ = runTake(e, m - n, true);
    @memset(U_KIND[e .. s + m], KIND_BODY);
    U_UNITS[s] = @intCast(m);
    return true;
}

// ---------------------------------------------------------------- API

pub const TRACK_LIVE = @import("build_options").track_live;
pub var LIVE_BYTES: usize = 0;
pub var DEALLOC_MISS: u32 = 0;
pub var ROC_BYTES: usize = 0;

inline fn classOf(len: usize) usize {
    return CLASS_UP[(@max(len, 1) + 15) / 16 - 1];
}

/// Test only (the exports `fail_next_alloc`, `fail_alloc_at` in host/host.zig): allocation
/// number FAIL_AT from now gives 0. 0: off.
pub var FAIL_AT: u32 = 0;

fn allocIn(t: *Task, len: usize, grow: bool) usize {
    if (FAIL_AT != 0) {
        FAIL_AT -= 1;
        if (FAIL_AT == 0) return 0;
    }
    const small = len <= SMALL_MAX;
    const class = if (small) classOf(len) else 0;
    const p = if (small) smallAlloc(t, class) else largeAlloc(t, len, grow);
    if (p == 0) return 0;
    const cap = if (small) CLASSES[class] else alignUp(len, CH);
    if (TRACK_LIVE) LIVE_BYTES +%= cap;
    return p;
}

pub fn hostAlloc(length: usize, alignment: usize) usize {
    return hostAllocFor(OWNER, length, alignment);
}

/// A block of `owner`. Owner 0 is the host: the block outlives the task that runs.
pub fn hostAllocFor(owner: usize, length: usize, alignment: usize) usize {
    _ = alignment;
    canary.check();
    return allocIn(taskOf(owner), length, false);
}

/// The unit of `ptr` when it is in a block of ours (a small page, or the first unit of a large block), else 0.
inline fn blockUnit(ptr: usize) usize {
    const u = ptr >> CH_SHIFT;
    if (u < POOL_LO or u >= POOL_HI) return 0;
    const k = U_KIND[u];
    return if (k == KIND_SMALL or k == KIND_LARGE) u else 0;
}

/// The capacity of the block at unit `u`, from `ptr` on.
inline fn usableAt(u: usize, ptr: usize) usize {
    if (U_KIND[u] == KIND_SMALL) return smallStart(ptr) + CLASSES[U_CLASS[u]] - ptr;
    return (u << CH_SHIFT) + (@as(usize, U_UNITS[u]) << CH_SHIFT) - ptr;
}

fn release(u: usize, ptr: usize) void {
    // The page tables of a task that ended are cleared, so `u` belongs to a live task.
    const t = &TASKS[U_SLOT[u]];
    if (U_KIND[u] == KIND_SMALL) {
        const cap = CLASSES[U_CLASS[u]];
        if (TRACK_LIVE) LIVE_BYTES -%= cap;
        smallFree(t, smallStart(ptr));
    } else {
        const cap = @as(usize, U_UNITS[u]) << CH_SHIFT;
        if (TRACK_LIVE) LIVE_BYTES -%= cap;
        largeFree(t, u);
    }
}

/// A block of the host, of JS, or of the task that runs may be freed. A late
/// free of a page that went to another task is a miss: that block is live.
inline fn mayFree(u: usize) bool {
    const s = U_SLOT[u];
    return s == 0 or s == JS_SLOT or SLOT_OWNER[s] == OWNER;
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const u = blockUnit(ptr);
    if (u != 0 and mayFree(u)) release(u, ptr) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    return hostReallocFor(OWNER, ptr, new_length, alignment);
}

/// As `hostRealloc`. A block that moves goes to `owner`.
pub fn hostReallocFor(owner: usize, ptr: usize, new_length: usize, alignment: usize) usize {
    _ = alignment;
    if (ptr == 0) return hostAllocFor(owner, new_length, 16);
    const u = blockUnit(ptr);
    if (u == 0) mem.trap();
    // A block of another task (a stale pointer) is a miss, as at free. The task cannot go on
    // without its block: a clean trap, before any change to the block or the tables.
    if (!mayFree(u)) {
        DEALLOC_MISS += 1;
        mem.trapClean();
    }
    const usable = usableAt(u, ptr);
    const large = U_KIND[u] == KIND_LARGE;
    if (new_length <= usable) {
        if (large) U_HW[u] = @intCast(ptr - (u << CH_SHIFT) + new_length);
        return ptr;
    }
    const end_ = ptr - (u << CH_SHIFT) + new_length;
    // A large block grows in place when the units after it are free.
    if (large and new_length > SMALL_MAX) {
        const m = (end_ + CH - 1) >> CH_SHIFT;
        const old = @as(usize, U_UNITS[u]) << CH_SHIFT;
        if (largeGrowInPlace(u, m, false) or (runFind(m) == 0 and largeGrowInPlace(u, m, true))) {
            U_HW[u] = @intCast(end_);
            const grown = (m << CH_SHIFT) - old;
            if (TRACK_LIVE) LIVE_BYTES +%= grown;
            return ptr;
        }
    }
    // Move: copy the used part only (large: up to the requested end). The new
    // block belongs to the task that runs (a JS block too: it needs no owner word then).
    const used = if (large) @as(usize, U_HW[u]) - (ptr - (u << CH_SHIFT)) else usable;
    const new_ptr = allocIn(taskOf(owner), new_length, true);
    if (new_ptr == 0) return 0;
    mem.copyBytes(new_ptr, ptr, @min(used, new_length));
    release(u, ptr);
    return new_ptr;
}

pub inline fn allocOrTrap(length: usize, alignment: usize) usize {
    const p = hostAlloc(length, alignment);
    if (p == 0) mem.trapClean();
    return p;
}
pub inline fn reallocOrTrap(ptr: usize, new_length: usize, alignment: usize) usize {
    const p = hostRealloc(ptr, new_length, alignment);
    if (p == 0) mem.trapClean();
    return p;
}

/// Host blocks (the log, the response): owner 0, and a clean trap when memory is out.
/// The owner is not changed, so the trap leaves OWNER as the task that runs.
pub inline fn allocHostOrTrap(length: usize, alignment: usize) usize {
    const p = hostAllocFor(0, length, alignment);
    if (p == 0) mem.trapClean();
    return p;
}
pub inline fn reallocHostOrTrap(ptr: usize, new_length: usize, alignment: usize) usize {
    const p = hostReallocFor(0, ptr, new_length, alignment);
    if (p == 0) mem.trapClean();
    return p;
}

/// A failed allocation is a clean trap: address 0 is the bottom of the stack.
pub export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    // 5b: a task that allocates after the CPU signal gets a clean trap.
    cpu.check();
    const p = hostAlloc(length, alignment);
    if (p == 0) mem.trapClean();
    ROC_BYTES += length;
    return @ptrFromInt(p);
}
export fn roc_dealloc(ptr: ?*anyopaque, alignment: usize) callconv(.c) void {
    _ = alignment;
    // An overflow traps here, before the free changes a table (PLAN.md 4-pre counts it clean).
    canary.check();
    hostDealloc(@intFromPtr(ptr));
}
pub export fn roc_realloc(ptr: ?*anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    cpu.check();
    const p = hostRealloc(@intFromPtr(ptr), new_length, alignment);
    if (p == 0) mem.trapClean();
    if (p != @intFromPtr(ptr)) ROC_BYTES += new_length;
    return @ptrFromInt(p);
}

/// The block start of `ptr` (a small block or a large block).
inline fn blockStart(u: usize, ptr: usize) usize {
    return if (U_KIND[u] == KIND_SMALL) smallStart(ptr) else u << CH_SHIFT;
}

/// A JS block now belongs to the task that runs: its owner word, so `freeOwner` finds it.
pub fn adopt(ptr: usize) void {
    const u = blockUnit(ptr);
    if (u != 0 and U_SLOT[u] == JS_SLOT) wrUsize(blockStart(u, ptr), OWNER);
}

/// Walk the JS pages and free the blocks adopted by `owner`.
fn freeAdopted(owner: usize) usize {
    var freed: usize = 0;
    var steps: usize = 0;
    const js = &TASKS[JS_SLOT];
    var h: usize = js.small_head;
    while (h != 0) {
        step(&steps);
        // Read the next page first: a free can give this page back.
        const next_page = U_NEXT[h];
        const base = h << CH_SHIFT;
        const size = CLASSES[U_CLASS[h]];
        const end_ = base + U_BUMP[h];
        var s = base;
        while (s < end_) : (s += size) {
            if (rdUsize(s) == owner) {
                freed += size;
                release(h, s);
                if (U_KIND[h] != KIND_SMALL) break;
            }
        }
        h = next_page;
    }
    var r: usize = js.large_head;
    while (r != 0) {
        step(&steps);
        const next = U_NEXT[r];
        if (rdUsize(r << CH_SHIFT) == owner) {
            freed += @as(usize, U_UNITS[r]) << CH_SHIFT;
            release(r, r << CH_SHIFT);
        }
        r = next;
    }
    return freed;
}

/// A walk of a list on tables that a wild write can damage (`freeOwner` runs also after an
/// unclean trap, PLAN.md 12c): trap after more steps than units, not loop for ever.
inline fn step(n: *usize) void {
    n.* += 1;
    if (n.* > MAX_UNITS) mem.trap();
}

/// The task ended (or trapped clean): give all its pages back. Returns its live bytes.
pub fn taskEnd(owner: usize) usize {
    if (owner == 0) return 0;
    const t = taskFind(owner) orelse return 0;
    var live: usize = 0;
    var steps: usize = 0;
    var p: usize = t.small_head;
    while (p != 0) {
        step(&steps);
        const next = U_NEXT[p];
        live += @as(usize, U_LIVE[p]) * CLASSES[U_CLASS[p]];
        U_INAV[p] = 0;
        smallGive(p);
        p = next;
    }
    p = t.large_head;
    while (p != 0) {
        step(&steps);
        const next = U_NEXT[p];
        live += @as(usize, U_UNITS[p]) << CH_SHIFT;
        U_HW[p] = 0;
        runGive(p, U_UNITS[p]);
        p = next;
    }
    if (TRACK_LIVE) LIVE_BYTES -%= live;
    SLOT_OWNER[t.slot] = 0;
    if (LAST_OWNER == owner) LAST_OWNER = 0;
    t.* = std.mem.zeroes(Task);
    return live;
}

/// Free every block of `owner` after a clean trap.
pub fn freeOwner(owner: usize) ?usize {
    if (owner == 0) return 0;
    const adopted = freeAdopted(owner);
    return taskEnd(owner) + adopted;
}

export fn dealloc_miss() u32 {
    return DEALLOC_MISS;
}
export fn heap_used() usize {
    return CHUNKS_USED << CH_SHIFT;
}
/// A block for JS to fill: [owner word][Roc refcount = 1][len bytes]. Returns the bytes.
/// Out of memory gives 0, with no trap: JS is in a host call, and no task runs. JS answers
/// the waiting task with status 4 (PLAN.md 2a).
pub export fn js_alloc(len: usize) usize {
    mem.enter();
    const p = allocIn(&TASKS[JS_SLOT], 8 + len, false);
    if (p == 0) return 0;
    wrUsize(p, 0);
    wrUsize(p + 4, 1);
    return p + 8;
}

pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
const vtable: std.mem.Allocator.VTable = .{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree };
fn vAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const p = hostAlloc(len, alignment.toByteUnits());
    return if (p == 0) null else @ptrFromInt(p);
}
fn vResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const u = blockUnit(@intFromPtr(buf.ptr));
    if (u == 0) return false;
    return new_len <= usableAt(u, @intFromPtr(buf.ptr));
}
fn vRemap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const p = hostRealloc(@intFromPtr(buf.ptr), new_len, alignment.toByteUnits());
    return if (p == 0) null else @ptrFromInt(p);
}
fn vFree(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    hostDealloc(@intFromPtr(buf.ptr));
}

// ---------------------------------------------------------------- sums

/// Fletcher sum (2 lanes of u64, s1 += w, s2 += s1) over [p, p + len). p and len are 16-aligned.
pub fn fletcher(p: usize, len: usize, seed: u64) u64 {
    const V = @Vector(2, u64);
    var s1: V = @splat(seed);
    var s2: V = @splat(0);
    var t1: V = @splat(0);
    var t2: V = @splat(0);
    const v = @as([*]const V, @ptrFromInt(p))[0 .. len / 16];
    var i: usize = 0;
    while (i + 1 < v.len) : (i += 2) {
        s1 +%= v[i];
        s2 +%= s1;
        t1 +%= v[i + 1];
        t2 +%= t1;
    }
    if (i < v.len) {
        s1 +%= v[i];
        s2 +%= s1;
    }
    return s1[0] ^ (s2[0] *% 3) ^ (s1[1] *% 5) ^ (s2[1] *% 7) ^ (t1[0] *% 11) ^ (t2[0] *% 13) ^ (t1[1] *% 17) ^ (t2[1] *% 19);
}

pub const SUM_K: u64 = 0x9E37_79B9_7F4A_7C15;
/// Sum of all memory of `owner`: its task record, its small pages up to the
/// bump offset, its large blocks up to the requested end, and the JS blocks that
/// it adopted. 12a calls it at each wait.
pub fn sumTask(owner: usize) u64 {
    var acc: u64 = 1;
    if (taskFind(owner)) |t| {
        acc = fletcher(@intFromPtr(t), @sizeOf(Task), 1);
        var steps: usize = 0;
        var h: usize = t.small_head;
        while (h != 0) : (h = U_NEXT[h]) {
            step(&steps);
            acc = acc *% SUM_K +% fletcher(h << CH_SHIFT, U_BUMP[h], h);
        }
        var r: usize = t.large_head;
        while (r != 0) : (r = U_NEXT[r]) {
            step(&steps);
            acc = acc *% SUM_K +% fletcher(r << CH_SHIFT, alignUp(U_HW[r], 16), r);
        }
    }
    return acc *% SUM_K +% sumAdopted(owner);
}

/// Sum of the JS blocks whose owner word is `owner` (a walk of the JS pages, as `freeAdopted`).
fn sumAdopted(owner: usize) u64 {
    var acc: u64 = 0;
    var steps: usize = 0;
    const js = &TASKS[JS_SLOT];
    var h: usize = js.small_head;
    while (h != 0) : (h = U_NEXT[h]) {
        step(&steps);
        const base = h << CH_SHIFT;
        const size = CLASSES[U_CLASS[h]];
        var s = base;
        while (s < base + U_BUMP[h]) : (s += size) {
            if (rdUsize(s) == owner) acc = acc *% SUM_K +% fletcher(s, size, s);
        }
    }
    var r: usize = js.large_head;
    while (r != 0) : (r = U_NEXT[r]) {
        step(&steps);
        if (rdUsize(r << CH_SHIFT) == owner) acc = acc *% SUM_K +% fletcher(r << CH_SHIFT, alignUp(U_HW[r], 16), r);
    }
    return acc;
}

/// PLAN.md 12b: `[p, len]` is the response block that JS wrote into `out` during a wait.
/// 0, 0 (no block), or a `js_alloc` block: the start of a block in a JS page, owner word 0
/// (not adopted), and room for `len` bytes (a large block: up to its requested end).
pub fn jsBlockOk(p: usize, len: usize) bool {
    if (p == 0) return len == 0;
    if (p < 8) return false;
    const b = p - 8;
    const u = blockUnit(b);
    if (u == 0 or U_SLOT[u] != JS_SLOT or blockStart(u, b) != b) return false;
    if (rdUsize(b) != 0) return false;
    const room = if (U_KIND[u] == KIND_SMALL) CLASSES[U_CLASS[u]] else U_HW[u];
    return len <= room - 8;
}

/// Test only (`poke_wait` in host/host.zig): the first JS block that `owner` adopted, or 0.
pub fn adoptedBlock(owner: usize) usize {
    const js = &TASKS[JS_SLOT];
    var h: usize = js.small_head;
    while (h != 0) : (h = U_NEXT[h]) {
        const base = h << CH_SHIFT;
        var s = base;
        while (s < base + U_BUMP[h]) : (s += CLASSES[U_CLASS[h]]) if (rdUsize(s) == owner) return s;
    }
    var r: usize = js.large_head;
    while (r != 0) : (r = U_NEXT[r]) if (rdUsize(r << CH_SHIFT) == owner) return r << CH_SHIFT;
    return 0;
}

// ---------------------------------------------------------------- global check (PLAN.md 12d)

/// Results of `checkTables` and of `check_heap` (host/host.zig). 0: the check passed.
pub const CHECK_POOL: u32 = 1; // pool bounds, a unit below the pool in use (foreign)
pub const CHECK_RUN: u32 = 2; // free runs: lists, lengths, joins, boundary tags
pub const CHECK_BITMAP: u32 = 3; // free bits that do not match the free runs
pub const CHECK_RESERVE: u32 = 4; // page reserve
pub const CHECK_TASK: u32 = 5; // task records, slots
pub const CHECK_SMALL: u32 = 6; // small page: kind, slot, class, bump, live count, task list
pub const CHECK_FREELIST: u32 = 7; // free list of a small page
pub const CHECK_AVAIL: u32 = 8; // lists of the pages with room
pub const CHECK_LARGE: u32 = 9; // large block
pub const CHECK_UNIT: u32 = 10; // a unit in no place, or in two
pub const CHECK_COUNT: u32 = 11; // CHUNKS_USED, LIVE_BYTES

/// Memory size at `init`. `poolInit` runs after it, at the first `js_alloc` (PLAN.md 12-pre).
var INIT_MEM_END: usize = 0;
pub fn markInit() void {
    INIT_MEM_END = @wasmMemorySize(0) * PAGE;
}

/// For the sum of constant data (host/host.zig `constSum`): the free mark and the allocator vtable.
pub fn sumConst(acc: u64) u64 {
    const a = mem.sumBytes(@intFromPtr(&FREE_MARK), @sizeOf(usize), acc);
    return mem.sumBytes(@intFromPtr(&vtable), @sizeOf(std.mem.Allocator.VTable), a);
}

/// The lowest address of the globals of this file with a start value (in `.data`, after `.rodata`).
pub fn firstData() usize {
    return @min(@min(@intFromPtr(&FREE_MARK), @intFromPtr(&TASKS)), @min(@intFromPtr(&SLOT_OWNER), @intFromPtr(&vtable)));
}

/// The units that the check found in a place. Only `checkTables` uses it.
var SEEN: [MAX_UNITS / 64]u64 = @splat(0);
inline fn see(u: usize) bool {
    const m = @as(u64, 1) << @intCast(u & 63);
    if (SEEN[u >> 6] & m != 0) return false;
    SEEN[u >> 6] |= m;
    return true;
}
inline fn inPool(u: usize) bool {
    return u >= POOL_LO and u < POOL_HI;
}

/// Each unit of the pool is in exactly one place: a free run, the reserve, a small page or a
/// large block of a task slot (the host and JS too), or foreign. The tables and counters agree.
/// It reads only the tables and the free blocks of small pages. 0: pass, else a `CHECK_*` code.
pub fn checkTables() u32 {
    const lo = POOL_LO;
    const hi = POOL_HI;
    const mem_end = @wasmMemorySize(0) * PAGE;
    // The pool and its bounds. `poolInit` runs before the roc runtime grows memory: no unit below
    // the pool is in use, and the pool starts at the memory end of `init`.
    if (hi == 0) {
        if (lo != 0 or CHUNKS_USED != 0 or CACHED != 0 or GROWN_END != 0) return CHECK_POOL;
    } else {
        if (lo == 0 or lo > hi or hi > MAX_UNITS or GROWN_END > mem_end) return CHECK_POOL;
        if (alignUp(GROWN_END, CH) >> CH_SHIFT != hi) return CHECK_POOL;
        if (INIT_MEM_END != 0 and alignUp(INIT_MEM_END, CH) >> CH_SHIFT != lo) return CHECK_POOL;
    }
    for (U_KIND[0..@min(lo, MAX_UNITS)]) |k| if (k != KIND_NONE) return CHECK_POOL;
    if (LOW_HINT > FREE_BITS.len) return CHECK_BITMAP;
    for (FREE_BITS[0..LOW_HINT]) |w| if (w != 0) return CHECK_BITMAP;
    @memset(SEEN[lo >> 6 .. (hi + 63) >> 6], 0);

    // Free runs: in the list of their length, boundary tags, joined, free bits set.
    var free_units: usize = 0;
    for (0..RL_FL) |fl| {
        if ((RL_FLBITS >> @intCast(fl)) & 1 != @intFromBool(RL_SLBITS[fl] != 0)) return CHECK_RUN;
        for (0..RL_SL) |sl| {
            var s: usize = RL_HEAD[fl][sl];
            if ((RL_SLBITS[fl] >> @intCast(sl)) & 1 != @intFromBool(s != 0)) return CHECK_RUN;
            var prev: usize = 0;
            while (s != 0) {
                if (!inPool(s)) return CHECK_RUN;
                const len: usize = U_UNITS[s];
                if (len == 0 or len > hi - s) return CHECK_RUN;
                const m = rmap(len);
                if (m.fl != fl or m.sl != sl or U_PREV[s] != prev) return CHECK_RUN;
                if (U_START[s + len - 1] != s) return CHECK_RUN;
                if ((s > lo and isFree(s - 1)) or (s + len < hi and isFree(s + len))) return CHECK_RUN;
                for (s..s + len) |u| {
                    if (!isFree(u)) return CHECK_BITMAP;
                    if (U_KIND[u] != KIND_NONE or !see(u)) return CHECK_UNIT;
                }
                free_units += len;
                prev = s;
                s = U_NEXT[s];
            }
        }
    }
    // No other free bit, in the pool or out of it.
    var bits: usize = 0;
    for (FREE_BITS) |w| bits += @popCount(w);
    if (bits != free_units) return CHECK_BITMAP;

    if (CACHED > CACHE_MAX) return CHECK_RESERVE;
    for (CACHE[0..CACHED]) |h| {
        if (!inPool(h) or U_KIND[h] != KIND_NONE) return CHECK_RESERVE;
        if (!see(h)) return CHECK_UNIT;
    }

    // Task slots: the host (0), the tasks, JS. A free slot has a zero record.
    if (SLOT_OWNER[0] != 0 or SLOT_OWNER[JS_SLOT] != std.math.maxInt(usize)) return CHECK_TASK;
    if (LAST_OWNER != 0 and (LAST_SLOT == 0 or LAST_SLOT >= JS_SLOT or SLOT_OWNER[LAST_SLOT] != LAST_OWNER)) return CHECK_TASK;
    var live: usize = 0;
    for (0..MAX_TASKS) |i| {
        const t = &TASKS[i];
        const owner = SLOT_OWNER[i];
        if (owner == 0 and i != 0) {
            if (!std.mem.allEqual(u8, std.mem.asBytes(t), 0)) return CHECK_TASK;
            continue;
        }
        const want: usize = if (i == 0 or i == JS_SLOT) 0 else owner;
        if (t.slot != i or t.owner != want) return CHECK_TASK;
        if (i != JS_SLOT) for (i + 1..JS_SLOT) |j| if (SLOT_OWNER[j] == owner and owner != 0) return CHECK_TASK;
        const c = checkSmallPages(t, i, &live);
        if (c != 0) return c;
        const l = checkLarge(t, i, &live);
        if (l != 0) return l;
    }

    // Each unit is in a place, or foreign.
    var foreign: usize = 0;
    for (lo..hi) |u| {
        const seen = (SEEN[u >> 6] >> @intCast(u & 63)) & 1 == 1;
        if (U_KIND[u] == KIND_FOREIGN) {
            if (seen or isFree(u)) return CHECK_UNIT;
            foreign += 1;
        } else if (!seen) return CHECK_UNIT;
    }
    if (CHUNKS_USED != (hi - lo) - free_units - foreign) return CHECK_COUNT;
    if (TRACK_LIVE and LIVE_BYTES != live) return CHECK_COUNT;
    return 0;
}

/// The small pages of slot `slot`: the task list links back, each page has a sound bump, live
/// count and free list (`slots - live` entries), and the lists of pages with room match `U_INAV`.
fn checkSmallPages(t: *const Task, slot: usize, live: *usize) u32 {
    var h: usize = t.small_head;
    var prev: usize = 0;
    var inav: usize = 0;
    while (h != 0) {
        if (!inPool(h) or U_KIND[h] != KIND_SMALL or U_SLOT[h] != slot or U_PREV[h] != prev) return CHECK_SMALL;
        if (!see(h)) return CHECK_UNIT;
        if (isFree(h)) return CHECK_BITMAP;
        const class: usize = U_CLASS[h];
        if (class >= NCLASS) return CHECK_SMALL;
        const size = CLASSES[class];
        const bump: usize = U_BUMP[h];
        if (bump < size or bump > CH or bump % size != 0) return CHECK_SMALL;
        const slots = bump / size;
        const n: usize = U_LIVE[h];
        if (n == 0 or n > slots) return CHECK_SMALL;
        if (freeListLen(h, size, bump, slots) != slots - n) return CHECK_FREELIST;
        // A page leaves its list of pages with room only when it is full.
        if (U_INAV[h] > 1 or (U_INAV[h] == 0 and (U_FREE[h] != 0 or bump + size <= CH))) return CHECK_AVAIL;
        inav += U_INAV[h];
        live.* += n * size;
        prev = h;
        h = U_NEXT[h];
    }
    var count: usize = 0;
    for (0..NCLASS) |c| {
        var a: usize = t.avail[c];
        var ap: usize = 0;
        while (a != 0) {
            if (!inPool(a) or U_KIND[a] != KIND_SMALL or U_SLOT[a] != slot or U_CLASS[a] != c or U_INAV[a] != 1 or U_APREV[a] != ap) return CHECK_AVAIL;
            count += 1;
            if (count > inav) return CHECK_AVAIL;
            ap = a;
            a = U_ANEXT[a];
        }
    }
    return if (count == inav) 0 else CHECK_AVAIL;
}

/// The number of entries of the free list of page `h`, or maxInt when an entry is not a free
/// block below the bump (a block start with the free mark), or the list has more entries than slots.
fn freeListLen(h: usize, size: usize, bump: usize, slots: usize) usize {
    const base = h << CH_SHIFT;
    var f: usize = U_FREE[h];
    var n: usize = 0;
    while (f != 0) {
        const off = f - 1;
        n += 1;
        if (off >= bump or off % size != 0 or n > slots) return std.math.maxInt(usize);
        if (rdUsize(base + off) != FREE_MARK) return std.math.maxInt(usize);
        f = rdUsize(base + off + 4);
    }
    return n;
}

fn checkLarge(t: *const Task, slot: usize, live: *usize) u32 {
    var s: usize = t.large_head;
    var prev: usize = 0;
    while (s != 0) {
        if (!inPool(s) or U_KIND[s] != KIND_LARGE or U_SLOT[s] != slot or U_PREV[s] != prev) return CHECK_LARGE;
        const n: usize = U_UNITS[s];
        if (n == 0 or n > POOL_HI - s or U_HW[s] > n << CH_SHIFT) return CHECK_LARGE;
        for (s..s + n) |u| {
            if (u != s and U_KIND[u] != KIND_BODY) return CHECK_LARGE;
            if (isFree(u)) return CHECK_BITMAP;
            if (!see(u)) return CHECK_UNIT;
        }
        live.* += n << CH_SHIFT;
        prev = s;
        s = U_NEXT[s];
    }
    return 0;
}

/// For the host check: `p` is the start of a block of the host (slot 0) with room for `len` bytes.
pub fn hostBlockOk(p: usize, len: usize) bool {
    return blockOf(p, 0, len);
}

/// For the host check: `p` is the start of a block of slot `slot` with room for `len` bytes.
pub fn slotBlockOk(p: usize, slot: usize, len: usize) bool {
    return blockOf(p, slot, len);
}

fn blockOf(p: usize, slot: usize, len: usize) bool {
    const u = blockUnit(p);
    if (u == 0 or U_SLOT[u] != slot) return false;
    if (U_KIND[u] == KIND_SMALL) return U_CLASS[u] < NCLASS and smallStart(p) == p and len <= CLASSES[U_CLASS[u]] and p - (u << CH_SHIFT) < U_BUMP[u];
    return p == u << CH_SHIFT and len <= U_HW[u];
}

/// The task slot of `owner` (not the host, not JS), or null.
pub fn slotOf(owner: usize) ?usize {
    if (owner == 0) return null;
    for (1..JS_SLOT) |i| if (SLOT_OWNER[i] == owner) return i;
    return null;
}

/// The number of task slots in use (not the host, not JS).
pub fn slotsInUse() usize {
    var n: usize = 0;
    for (SLOT_OWNER[1..JS_SLOT]) |o| n += @intFromBool(o != 0);
    return n;
}

/// Test only (`break_table` in host/host.zig, `bench/checkheap-test.mjs`): a wild write into one
/// table entry, with no trap. `arg`: a task id for the kinds that take a page of a task (0: any).
/// Returns 1 when it found a target, else 0.
pub fn breakTable(kind: u32, arg: usize) u32 {
    switch (kind) {
        // 1: the length of a free run (its boundary tag no longer matches).
        1 => {
            const s = anyRun(1) orelse return 0;
            U_UNITS[s] += 1;
        },
        // 2: the free bit of a unit in use (a small page).
        2 => {
            const h = smallPageOf(arg, false) orelse return 0;
            FREE_BITS[h >> 6] |= @as(u64, 1) << @intCast(h & 63);
        },
        // 3: the boundary tag at the end of a free run of 2 units or more.
        3 => {
            const s = anyRun(2) orelse return 0;
            U_START[s + U_UNITS[s] - 1] +%= 1;
        },
        // 4: a reserve page twice in the reserve.
        4 => {
            if (CACHED == 0 or CACHED >= CACHE_MAX) return 0;
            CACHE[CACHED] = CACHE[CACHED - 1];
            CACHED += 1;
        },
        // 5: a small page in use also in the reserve.
        5 => {
            const h = smallPageOf(arg, false) orelse return 0;
            if (CACHED >= CACHE_MAX) return 0;
            CACHE[CACHED] = @intCast(h);
            CACHED += 1;
        },
        // 6: the live count of a small page.
        6 => {
            const h = smallPageOf(arg, false) orelse return 0;
            U_LIVE[h] += 1;
        },
        // 7: the free list of a small page with room points to a live block (the last one given out).
        7 => {
            const h = smallPageOf(arg, false) orelse return 0;
            if (U_INAV[h] != 1) return 0;
            U_FREE[h] = @intCast(U_BUMP[h] - CLASSES[U_CLASS[h]] + 1);
        },
        // 8: the back link of the second small page of a task list.
        8 => {
            const h = smallPageOf(arg, true) orelse return 0;
            U_PREV[U_NEXT[h]] +%= 1;
        },
        // 9: a page with room that leaves its list of pages with room (`U_INAV`).
        9 => {
            const h = smallPageOf(arg, false) orelse return 0;
            if (U_INAV[h] != 1) return 0;
            U_INAV[h] = 0;
        },
        // 10: the slot of a large block.
        10 => {
            const s = largeBlockOf(arg) orelse return 0;
            U_SLOT[s] = if (U_SLOT[s] == 1) 2 else 1;
        },
        // 11: a small page in use marked foreign.
        11 => {
            const h = smallPageOf(arg, false) orelse return 0;
            U_KIND[h] = KIND_FOREIGN;
        },
        // 12: a foreign unit below the pool (the runtime grew memory before `poolInit`).
        12 => {
            if (POOL_LO == 0) return 0;
            U_KIND[POOL_LO - 1] = KIND_FOREIGN;
        },
        // 13: the owner of a task slot.
        13 => {
            const s = slotOf(arg) orelse (for (1..JS_SLOT) |i| {
                if (SLOT_OWNER[i] != 0) break i;
            } else return 0);
            SLOT_OWNER[s] +%= 1;
        },
        // 14: the live byte count.
        14 => LIVE_BYTES +%= 16,
        // 15: the count of used units.
        15 => CHUNKS_USED +%= 1,
        // 16: the free mark (constant data after `init`).
        16 => FREE_MARK ^= 2,
        else => return 0,
    }
    return 1;
}

/// A free run of at least `n` units, or null.
fn anyRun(n: usize) ?usize {
    for (RL_HEAD) |row| for (row) |s| {
        var r: usize = s;
        while (r != 0) : (r = U_NEXT[r]) if (U_UNITS[r] >= n) return r;
    };
    return null;
}

/// The first small page of task `owner` (0: of any task), else of the host or JS. `linked`: a
/// page with a next page in its task list (for kind 8).
fn smallPageOf(owner: usize, linked: bool) ?usize {
    const first = slotOf(owner) orelse 1;
    var order: [MAX_TASKS + 1]usize = undefined;
    order[0] = first;
    for (0..MAX_TASKS) |i| order[i + 1] = if (owner == 0) (i + 1) % MAX_TASKS else i;
    for (order) |sl| {
        const h: usize = TASKS[sl].small_head;
        if (h != 0 and (!linked or U_NEXT[h] != 0)) return h;
    }
    return null;
}

/// The first large block of task `owner` (0: of any slot), or null.
fn largeBlockOf(owner: usize) ?usize {
    if (slotOf(owner)) |s| if (TASKS[s].large_head != 0) return TASKS[s].large_head;
    for (0..MAX_TASKS) |i| if (TASKS[i].large_head != 0) return TASKS[i].large_head;
    return null;
}
