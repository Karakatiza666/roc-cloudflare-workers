//! Prototype v6: v5 without TLSF and without block headers.
//! Units: 4 KB, max 128 MB (u16 indexes). Free units: a bitmap (to find the lowest
//! free unit) and segregated lists of free runs by length (TLSF lists over runs).
//! Small blocks (<= 2048 B): one size class per 4 KB page, pages per task, at the
//! lowest free unit. No header: the page tables give the class and the task.
//! Other blocks: their own run of units, best fit, at the top end of the run.
//! A block that a realloc moves goes to the low end of a run with room, so that
//! the next realloc can grow it in place.
//! JS blocks (`js_alloc`) are in their own pages, with an owner word for `adopt`.
//! Live data never moves: Roc values and saved stacks hold raw addresses.

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
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
pub var GROWS: usize = 0;
pub var SMALL_PAGES_TAKEN: usize = 0;
pub var GROWN_IN_PLACE: usize = 0;
/// Grow step in units (the developer option `growStepBytes`).
pub var GROW_CHUNKS: usize = PAGE >> CH_SHIFT;
export fn set_grow_chunks(n: usize) void {
    GROW_CHUNKS = n;
}

/// Placement of a block that a realloc moves (it grows): the low end of a free
/// run of at least GROW_ROOM times its size, else of the best fit. 0: as other
/// large blocks (best fit, top end). 255: the largest free run.
var GROW_ROOM: u8 = 2;
export fn set_place(m: u8) void {
    GROW_ROOM = m;
}
/// Empty small pages: 0 = give back at once, 1 = keep the only page of its class
/// with room (Hoard: at most one empty page per class), 2 = keep until the task ends.
var KEEP_EMPTY: u8 = 1;
export fn set_keep_empty(m: u8) void {
    KEEP_EMPTY = m;
}
/// Empty small pages go to a stack that only small pages use (no bitmap, no
/// joins): 1 = on. A test of a region reserved for small pages.
var PAGE_CACHE: u8 = 0;
var CACHE: [MAX_UNITS]u16 = @splat(0);
var CACHED: usize = 0;
export fn set_page_cache(m: u8) void {
    PAGE_CACHE = m;
}
/// The most pages the stack holds: more go back to the pool.
var CACHE_MAX: usize = MAX_UNITS;
export fn set_cache_max(n: usize) void {
    CACHE_MAX = n;
}
fn smallGive(h: usize) void {
    if (PAGE_CACHE == 1 and CACHED < CACHE_MAX) {
        U_KIND[h] = KIND_NONE;
        CACHE[CACHED] = @intCast(h);
        CACHED += 1;
    } else runGive(h, 1);
}
/// Before a large block takes new memory at the top: 1 = grow in place there first.
var GROW_AT_TOP: u8 = 1;
export fn set_grow_at_top(m: u8) void {
    GROW_AT_TOP = m;
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

/// The longest free run (the longest of the first runs in the top list). 0 when none.
fn runLargest() usize {
    if (RL_FLBITS == 0) return 0;
    const fl: usize = 15 - @clz(RL_FLBITS);
    const sl: usize = 7 - @as(usize, @clz(RL_SLBITS[fl]));
    var best: usize = 0;
    var r: usize = RL_HEAD[fl][sl];
    var k: u32 = 0;
    while (r != 0 and k < 8) : (k += 1) {
        if (best == 0 or U_UNITS[r] > U_UNITS[best]) best = r;
        r = U_NEXT[r];
    }
    return best;
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
    GROWS += 1;
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
/// low end of a run with room. 0 on out-of-memory.
fn takeRun(n: usize, grow: bool) usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        if (grow and GROW_ROOM != 0) {
            const r = if (GROW_ROOM == 255) runLargest() else runFind(n * GROW_ROOM);
            if (r != 0 and U_UNITS[r] >= n) return runTake(r, n, true);
        }
        const r = runFind(n);
        if (r != 0) return runTake(r, n, grow and GROW_ROOM != 0);
        if (!poolGrow(n)) return 0;
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
    live: usize,
    avail: [NCLASS]u16, // per class: the pages that can have room (U_ANEXT, U_APREV)
    _pad: [64 - 20 - 2 * NCLASS]u8,
};
comptime {
    std.debug.assert(@sizeOf(Task) % 16 == 0);
}
const MAX_TASKS = 256;
/// The slot of JS blocks (`js_alloc`): they have an owner word for `adopt`.
const JS_SLOT = MAX_TASKS - 1;
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
pub var TASK_OVERFLOW: u32 = 0;

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
    if (free_slot == 0) {
        TASK_OVERFLOW += 1;
        mem.trap();
    }
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
            U_LIVE[h] += 1;
            return p;
        }
        const b: usize = U_BUMP[h];
        if (b + size <= CH) {
            U_BUMP[h] = @intCast(b + size);
            U_LIVE[h] += 1;
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
    SMALL_PAGES_TAKEN += 1;
    U_KIND[h] = KIND_SMALL;
    U_SLOT[h] = @intCast(t.slot);
    U_CLASS[h] = @intCast(class);
    U_LIVE[h] = 1;
    U_BUMP[h] = @intCast(size);
    U_FREE[h] = 0;
    listPush(&t.small_head, h);
    availPush(t, h);
    return h << CH_SHIFT;
}

/// The start of the small block that holds `ptr`.
inline fn smallStart(ptr: usize) usize {
    const base = ptr & ~(CH - 1);
    const idx: usize = @intCast(((ptr - base) * RECIP[U_CLASS[ptr >> CH_SHIFT]]) >> 32);
    return base + idx * CLASSES[U_CLASS[ptr >> CH_SHIFT]];
}

/// Free the small block at `p` (its start). An empty page goes back, except
/// when it is the only page of its class with room.
fn smallFree(t: *Task, p: usize) void {
    const h = p >> CH_SHIFT;
    // Word 0 = 0: a free block of a JS page has no owner.
    wrUsize(p, 0);
    wrUsize(p + 4, U_FREE[h]);
    U_FREE[h] = @intCast(p - (h << CH_SHIFT) + 1);
    U_LIVE[h] -= 1;
    if (U_INAV[h] == 0) availPush(t, h);
    if (U_LIVE[h] == 0 and (KEEP_EMPTY == 0 or (KEEP_EMPTY == 1 and (U_ANEXT[h] != 0 or U_APREV[h] != 0)))) {
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
    GROWN_IN_PLACE += 1;
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

fn allocIn(t: *Task, len: usize, grow: bool) usize {
    const small = len <= SMALL_MAX;
    const class = if (small) classOf(len) else 0;
    const p = if (small) smallAlloc(t, class) else largeAlloc(t, len, grow);
    if (p == 0) return 0;
    const cap = if (small) CLASSES[class] else alignUp(len, CH);
    t.live +%= cap;
    if (TRACK_LIVE) LIVE_BYTES +%= cap;
    // probe: alloc
    return p;
}

pub fn hostAlloc(length: usize, alignment: usize) usize {
    _ = alignment;
    canary.check();
    return allocIn(taskOf(OWNER), length, false);
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
    const slot = U_SLOT[u];
    if (slot != 0 and SLOT_OWNER[slot] == 0) {
        DEALLOC_MISS += 1;
        return;
    }
    const t = &TASKS[slot];
    if (U_KIND[u] == KIND_SMALL) {
        const cap = CLASSES[U_CLASS[u]];
        t.live -%= cap;
        if (TRACK_LIVE) LIVE_BYTES -%= cap;
        smallFree(t, smallStart(ptr));
    } else {
        const cap = @as(usize, U_UNITS[u]) << CH_SHIFT;
        t.live -%= cap;
        if (TRACK_LIVE) LIVE_BYTES -%= cap;
        largeFree(t, u);
    }
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const u = blockUnit(ptr);
    if (u != 0) release(u, ptr) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    _ = alignment;
    if (ptr == 0) return hostAlloc(new_length, 16);
    const u = blockUnit(ptr);
    if (u == 0) mem.trap();
    const usable = usableAt(u, ptr);
    const large = U_KIND[u] == KIND_LARGE;
    if (new_length <= usable) {
        if (large) U_HW[u] = @intCast(ptr - (u << CH_SHIFT) + new_length);
        return ptr;
    }
    const slot = U_SLOT[u];
    const t = &TASKS[slot];
    const end_ = ptr - (u << CH_SHIFT) + new_length;
    // A large block grows in place when the units after it are free.
    if (large and new_length > SMALL_MAX) {
        const m = (end_ + CH - 1) >> CH_SHIFT;
        const old = @as(usize, U_UNITS[u]) << CH_SHIFT;
        if (largeGrowInPlace(u, m, false) or (GROW_AT_TOP == 1 and runFind(m) == 0 and largeGrowInPlace(u, m, true))) {
            U_HW[u] = @intCast(end_);
            const grown = (m << CH_SHIFT) - old;
            t.live +%= grown;
            if (TRACK_LIVE) LIVE_BYTES +%= grown;
            return ptr;
        }
    }
    // Move: copy the used part only (large: up to the requested end). The new
    // block belongs to the task that runs (a JS block too: it needs no owner word then).
    const used = if (large) @as(usize, U_HW[u]) - (ptr - (u << CH_SHIFT)) else usable;
    const new_ptr = allocIn(taskOf(OWNER), new_length, true);
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

export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    ROC_BYTES += length;
    return @ptrFromInt(hostAlloc(length, alignment));
}
export fn roc_dealloc(ptr: ?*anyopaque, alignment: usize) callconv(.c) void {
    _ = alignment;
    hostDealloc(@intFromPtr(ptr));
}
export fn roc_realloc(ptr: ?*anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const p = hostRealloc(@intFromPtr(ptr), new_length, alignment);
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
    const js = &TASKS[JS_SLOT];
    var h: usize = js.small_head;
    while (h != 0) {
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
        const next = U_NEXT[r];
        if (rdUsize(r << CH_SHIFT) == owner) {
            freed += @as(usize, U_UNITS[r]) << CH_SHIFT;
            release(r, r << CH_SHIFT);
        }
        r = next;
    }
    return freed;
}

pub var LEAKED_AT_END: usize = 0;

/// The task ended (or trapped clean): give all its pages back. Returns its live bytes.
pub fn taskEnd(owner: usize) usize {
    if (owner == 0) return 0;
    const t = taskFind(owner) orelse return 0;
    const live = t.live;
    if (TRACK_LIVE) LIVE_BYTES -%= live;
    var p: usize = t.small_head;
    while (p != 0) {
        const next = U_NEXT[p];
        U_INAV[p] = 0;
        smallGive(p);
        p = next;
    }
    p = t.large_head;
    while (p != 0) {
        const next = U_NEXT[p];
        U_HW[p] = 0;
        runGive(p, U_UNITS[p]);
        p = next;
    }
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
export fn heap_grows() usize {
    return GROWS;
}
export fn small_pages_taken() usize {
    return SMALL_PAGES_TAKEN;
}
export fn grown_in_place() usize {
    return GROWN_IN_PLACE;
}
/// Public for the replay tests (replay/replay.zig op 8).
pub const JS_ALLOC_PUB = true;
/// A block for JS to fill: [owner word][Roc refcount = 1][len bytes]. Returns the bytes.
pub export fn js_alloc(len: usize) usize {
    const p = allocIn(&TASKS[JS_SLOT], 8 + len, false);
    if (p == 0) mem.trapClean();
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

pub var SUM_BYTES: u64 = 0;
/// Sum of all memory of `owner`: its task record, its small pages up to the
/// bump offset, and its large blocks up to the requested end.
pub fn sumTask(owner: usize) u64 {
    const t = taskFind(owner) orelse return 0;
    var acc: u64 = fletcher(@intFromPtr(t), @sizeOf(Task), 1);
    var h: usize = t.small_head;
    while (h != 0) : (h = U_NEXT[h]) {
        const len: usize = U_BUMP[h];
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(h << CH_SHIFT, len, h);
        SUM_BYTES += len;
    }
    var r: usize = t.large_head;
    while (r != 0) : (r = U_NEXT[r]) {
        const len = alignUp(U_HW[r], 16);
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(r << CH_SHIFT, len, r);
        SUM_BYTES += len;
    }
    return acc;
}

/// Old prototype entry point (the walk version), kept for the host code: mode 2 = no sum.
pub fn sumOwner(owner: usize, mode: u32) u64 {
    return if (mode == 2) 0 else sumTask(owner);
}
