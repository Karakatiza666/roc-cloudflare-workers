//! Prototype v5: small pages at the bottom, large pages at the top.
//! Units: 4 KB. A free bitmap over the units (max 128 MB, so u16 indexes).
//! Small pages (4, 8, 16, 32 KB; a task's next page in a class doubles): the
//! lowest free run that fits. One size class per page, a free list and a live
//! count per page (Hoard, mimalloc). An empty page goes back at once, except the
//! last page with room in its class.
//! Large pages (128 KB to 1 MB; a task's next page doubles): the highest free run
//! that fits, at its top end. The task sub-allocates them with TLSF (Masmano et
//! al. 2008): join, split, grow in place. A page that is all free goes back.
//! Huge blocks (> 256 KB): their own run of units, from the top.
//! A hole is used again by the next page that fits. Live data never moves:
//! Roc values and saved stacks hold raw addresses.
//! Span header: [capacity @0][owner, or next free @4][capacity ^ magic @8][@12: small: requested end; large: prev phys].

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
const CH_SHIFT = 12;
const CH: usize = 1 << CH_SHIFT;
/// The heap limit is 128 MB, so unit indexes fit in u16.
const MAX_UNITS: usize = (128 << 20) >> CH_SHIFT;
const SMALL_MAX: usize = 4096;
/// Blocks above this get their own run (huge). set_large_max(4096): no TLSF (step 1 of the v6 plan).
var LARGE_MAX: usize = 256 * 1024;
export fn set_large_max(n: usize) void {
    LARGE_MAX = n;
}

pub var OWNER: usize = 0;
pub const HEADER_SIZE: usize = 16;
const SPAN_MAGIC: usize = 0xC0DE_5AFE;

inline fn sealSpan(span: usize) void {
    wrUsize(span + 8, rdUsize(span) ^ SPAN_MAGIC);
}
pub inline fn spanIsSealed(span: usize) bool {
    const capacity = rdUsize(span);
    return capacity != 0 and capacity % 16 == 0 and rdUsize(span + 8) == capacity ^ SPAN_MAGIC;
}
pub inline fn spanOf(ptr: usize) usize {
    if (ptr < 32) return 0;
    const candidate = (ptr - 16) & ~@as(usize, 15);
    return if (spanIsSealed(candidate)) candidate else 0;
}

// ---------------------------------------------------------------- units

const KIND_NONE: u8 = 0;
const KIND_SMALL: u8 = 1;
const KIND_LARGE: u8 = 2;
const KIND_HUGE: u8 = 3;
const KIND_FOREIGN: u8 = 4;
/// Per unit: the kind, the owner slot and the first unit of its page.
var U_KIND: [MAX_UNITS]u8 = @splat(0);
var U_SLOT: [MAX_UNITS]u8 = @splat(0);
var U_HEAD: [MAX_UNITS]u16 = @splat(0);
// Per page (at its first unit):
var U_UNITS: [MAX_UNITS]u16 = @splat(0);
/// A task's small pages (doubly linked), large pages, or huge blocks (doubly linked).
var U_NEXT: [MAX_UNITS]u16 = @splat(0);
var U_PREV: [MAX_UNITS]u16 = @splat(0);
/// Large pages: the end of the used part (the sum walk stops there). Huge: the requested end.
var U_HW: [MAX_UNITS]u32 = @splat(0);
// Small pages: one size class each, with their own free list and live count.
var U_CLASS: [MAX_UNITS]u8 = @splat(0);
var U_LIVE: [MAX_UNITS]u16 = @splat(0);
var U_BUMP: [MAX_UNITS]u16 = @splat(0);
/// Offset + 1 of the first free block in the page, 0 when empty.
var U_FREE: [MAX_UNITS]u16 = @splat(0);
/// Small pages of a task and class that have room (doubly linked).
var U_ANEXT: [MAX_UNITS]u16 = @splat(0);
var U_APREV: [MAX_UNITS]u16 = @splat(0);
pub var CHUNKS_RETIRED: usize = 0;

var FREE_BITS: [MAX_UNITS / 64]u64 = @splat(0);
/// No free unit in the bitmap words below this one.
var LOW_HINT: usize = 0;
var POOL_LO: usize = 0;
var POOL_HI: usize = 0;
/// The memory end after our last grow: memory above it was grown by other code.
var GROWN_END: usize = 0;
pub var CHUNKS_USED: usize = 0;
pub var GROWS: usize = 0;
/// Grow step in units (the developer option `growStepBytes`).
pub var GROW_CHUNKS: usize = PAGE >> CH_SHIFT;
/// Large pages: the first is LARGE_BASE units, then doubling LARGE_STEPS times.
var LARGE_BASE: usize = 4;
var LARGE_STEPS: u8 = 0;
export fn set_large_min_run(n: usize) void {
    LARGE_BASE = n;
}
export fn set_grow_chunks(n: usize) void {
    GROW_CHUNKS = n;
}
export fn set_large_steps(n: u8) void {
    LARGE_STEPS = n;
}
/// Small pages: 4 KB, then doubling SMALL_STEPS times.
var SMALL_STEPS: u8 = 0;
export fn set_small_steps(n: u8) void {
    SMALL_STEPS = n;
}

inline fn isFree(i: usize) bool {
    return (FREE_BITS[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}
inline fn setFree(i: usize, f: bool) void {
    const bit = @as(u64, 1) << @intCast(i & 63);
    if (f) {
        FREE_BITS[i >> 6] |= bit;
        if ((i >> 6) < LOW_HINT) LOW_HINT = i >> 6;
    } else FREE_BITS[i >> 6] &= ~bit;
}

fn poolInit() void {
    if (POOL_HI != 0) return;
    GROWN_END = @wasmMemorySize(0) * PAGE;
    POOL_LO = alignUp(GROWN_END, CH) >> CH_SHIFT;
    POOL_HI = POOL_LO;
}

/// Grow memory so that the free run at the top has `n` units. False on out-of-memory.
fn poolGrow(n: usize) bool {
    const top = @wasmMemorySize(0) * PAGE;
    // Other code (Roc's boxy runtime) grew memory: those units are not ours.
    if (top > GROWN_END) {
        const hi = alignUp(top, CH) >> CH_SHIFT;
        var i = POOL_HI;
        while (i < hi) : (i += 1) U_KIND[i] = KIND_FOREIGN;
        POOL_HI = hi;
        GROWN_END = top;
    }
    var have: usize = 0;
    while (have < n and POOL_HI - have > POOL_LO and isFree(POOL_HI - 1 - have)) have += 1;
    const want = @max(n - have, GROW_CHUNKS);
    const pages = (want * CH + PAGE - 1) / PAGE;
    if (POOL_HI + pages * (PAGE / CH) > MAX_UNITS) return false;
    if (@wasmMemoryGrow(0, pages) < 0) return false;
    GROWS += 1;
    GROWN_END = @wasmMemorySize(0) * PAGE;
    const hi = GROWN_END >> CH_SHIFT;
    var i = POOL_HI;
    while (i < hi) : (i += 1) setFree(i, true);
    POOL_HI = hi;
    return true;
}

fn markUsed(first: usize, n: usize) void {
    var k = first;
    while (k < first + n) : (k += 1) setFree(k, false);
    CHUNKS_USED += n;
}

/// The lowest run of `n` free units (first fit from the bottom). 0 on out-of-memory.
fn takeLow(n: usize) usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        var i = @max(POOL_LO, LOW_HINT << 6);
        var run: usize = 0;
        while (i < POOL_HI) {
            if ((i & 63) == 0 and FREE_BITS[i >> 6] == 0) {
                if (LOW_HINT == (i >> 6)) LOW_HINT += 1;
                run = 0;
                i += 64;
                continue;
            }
            if (isFree(i)) {
                run += 1;
                if (run == n) {
                    markUsed(i + 1 - n, n);
                    return i + 1 - n;
                }
            } else run = 0;
            i += 1;
        }
        if (!poolGrow(n)) return 0;
    }
    return 0;
}

/// Large placement: 0 = highest run that fits, 1 = best fit (the smallest run that fits, the highest of equals).
var PLACE: u8 = 1;
export fn set_place(m: u8) void {
    PLACE = m;
}

/// The top `n` units of the smallest free run that fits (the highest of equals). 0 when none.
fn bestHigh(n: usize) usize {
    var best_top: usize = 0;
    var best_len: usize = std.math.maxInt(usize);
    var i = POOL_HI;
    var run: usize = 0;
    while (i > POOL_LO) {
        if ((i & 63) == 0 and i >= POOL_LO + 64) {
            const w = FREE_BITS[(i >> 6) - 1];
            if (w == 0) {
                if (run >= n and run < best_len) {
                    best_len = run;
                    best_top = i + run;
                }
                run = 0;
                i -= 64;
                continue;
            }
            if (w == ~@as(u64, 0)) {
                run += 64;
                i -= 64;
                continue;
            }
        }
        i -= 1;
        if (isFree(i)) run += 1 else {
            if (run >= n and run < best_len) {
                best_len = run;
                best_top = i + 1 + run;
            }
            run = 0;
        }
    }
    if (run >= n and run < best_len) best_top = i + run;
    if (best_top == 0) return 0;
    markUsed(best_top - n, n);
    return best_top - n;
}

/// The top `n` units of the highest free run that fits. 0 on out-of-memory.
fn takeHigh(n: usize) usize {
    poolInit();
    if (PLACE == 1) {
        const b = bestHigh(n);
        if (b != 0) return b;
        if (!poolGrow(n)) return 0;
        return bestHigh(n);
    }
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        var i = POOL_HI;
        var run: usize = 0;
        while (i > POOL_LO) {
            if ((i & 63) == 0 and i >= POOL_LO + 64 and FREE_BITS[(i >> 6) - 1] == 0) {
                run = 0;
                i -= 64;
                continue;
            }
            i -= 1;
            if (isFree(i)) {
                run += 1;
                if (run == n) {
                    markUsed(i, n);
                    return i;
                }
            } else run = 0;
        }
        if (!poolGrow(n)) return 0;
    }
    return 0;
}

fn poolGive(first: usize, n: usize) void {
    var k = first;
    while (k < first + n) : (k += 1) {
        U_KIND[k] = KIND_NONE;
        U_SLOT[k] = 0;
        U_HEAD[k] = 0;
        setFree(k, true);
    }
    U_UNITS[first] = 0;
    U_NEXT[first] = 0;
    U_PREV[first] = 0;
    U_ANEXT[first] = 0;
    U_APREV[first] = 0;
    CHUNKS_USED -= n;
}

fn markPage(first: usize, n: usize, kind: u8, slot: u32) void {
    var k = first;
    while (k < first + n) : (k += 1) {
        U_KIND[k] = kind;
        U_SLOT[k] = @intCast(slot);
        U_HEAD[k] = @intCast(first);
    }
    U_UNITS[first] = @intCast(n);
}

// ---------------------------------------------------------------- tasks

const CLASSES = [16]usize{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
const CLASS_SLOTS: usize = 4096 / 16;
const CLASS_UP: [CLASS_SLOTS]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [CLASS_SLOTS]u8 = undefined;
    for (0..CLASS_SLOTS) |s| {
        const total = (s + 1) * 16;
        var c = 0;
        while (CLASSES[c] < total) c += 1;
        t[s] = c;
    }
    break :blk t;
};
inline fn classOf(total: usize) ?usize {
    if (total == 0 or total > 4096) return null;
    return CLASS_UP[(total + 15) / 16 - 1];
}

const FL_MIN = 5; // free large blocks are at least 32 B
const FL_COUNT = 32 - FL_MIN;
const SL_BITS = 3;
const SL_COUNT = 1 << SL_BITS;

const Task = extern struct {
    owner: usize,
    slot: u32,
    small_head: u32, // all small pages (U_NEXT, U_PREV)
    large_head: u32, // all large pages (U_NEXT)
    huge_head: u32, // all huge blocks (U_NEXT, U_PREV)
    fl_bits: u32,
    live: usize,
    nlarge: u8, // large pages now: the next one is 128 KB << nlarge (to 1 MB)
    _pad: [3]u8,
    avail: [16]u16, // per class: the pages with room (U_ANEXT, U_APREV)
    nsmall: [16]u8, // per class: small pages now: the next one is 4 KB << nsmall (to 32 KB)
    sl_bits: [32]u8,
    free: [FL_COUNT][SL_COUNT]usize,
};
comptime {
    std.debug.assert(@sizeOf(Task) % 16 == 0);
}
const MAX_TASKS = 256;
var TASKS: [MAX_TASKS]Task align(16) = std.mem.zeroes([MAX_TASKS]Task);
/// SLOT_OWNER[i]: the task in slot i, 0 when the slot is free. Slot 0 is the host.
var SLOT_OWNER: [MAX_TASKS]usize = @splat(0);
var LAST_OWNER: usize = 0;
var LAST_SLOT: usize = 0;
pub var TASK_OVERFLOW: u32 = 0;

/// The record of `owner`, made on first use.
fn taskOf(owner: usize) *Task {
    if (owner == 0) return &TASKS[0];
    if (owner == LAST_OWNER) return &TASKS[LAST_SLOT];
    var free_slot: usize = 0;
    for (1..MAX_TASKS) |i| {
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
    for (1..MAX_TASKS) |i| if (SLOT_OWNER[i] == owner) return &TASKS[i];
    return null;
}

// ---------------------------------------------------------------- small pages

inline fn pageEnd(h: usize) usize {
    return @as(usize, U_UNITS[h]) << CH_SHIFT;
}

inline fn pageFull(h: usize) bool {
    return U_FREE[h] == 0 and @as(usize, U_BUMP[h]) + CLASSES[U_CLASS[h]] > pageEnd(h);
}

fn availPush(t: *Task, h: usize) void {
    const class = U_CLASS[h];
    const head = t.avail[class];
    U_ANEXT[h] = head;
    U_APREV[h] = 0;
    if (head != 0) U_APREV[head] = @intCast(h);
    t.avail[class] = @intCast(h);
}

fn availRemove(t: *Task, h: usize) void {
    const n = U_ANEXT[h];
    const p = U_APREV[h];
    if (p != 0) U_ANEXT[p] = n else t.avail[U_CLASS[h]] = n;
    if (n != 0) U_APREV[n] = p;
    U_ANEXT[h] = 0;
    U_APREV[h] = 0;
}

fn smallAlloc(t: *Task, class: usize) usize {
    var h: usize = t.avail[class];
    if (h == 0) {
        const n = @as(usize, 1) << @intCast(@min(t.nsmall[class], SMALL_STEPS));
        h = takeLow(n);
        if (h == 0) return 0;
        markPage(h, n, KIND_SMALL, t.slot);
        t.nsmall[class] +|= 1;
        U_CLASS[h] = @intCast(class);
        U_LIVE[h] = 0;
        U_BUMP[h] = 0;
        U_FREE[h] = 0;
        U_NEXT[h] = @intCast(t.small_head);
        U_PREV[h] = 0;
        if (t.small_head != 0) U_PREV[t.small_head] = @intCast(h);
        t.small_head = @intCast(h);
        availPush(t, h);
    }
    var s: usize = U_FREE[h];
    if (s != 0) {
        s += (h << CH_SHIFT) - 1;
        U_FREE[h] = @intCast(rdUsize(s + 4));
    } else {
        s = (h << CH_SHIFT) + U_BUMP[h];
        U_BUMP[h] += @intCast(CLASSES[class]);
    }
    U_LIVE[h] += 1;
    if (pageFull(h)) availRemove(t, h);
    wrUsize(s, CLASSES[class]);
    return s;
}

/// Give an empty small page back, unless it is the last page with room in its class.
fn smallFree(t: *Task, span: usize) void {
    const h: usize = U_HEAD[span >> CH_SHIFT];
    const was_full = pageFull(h);
    wrUsize(span + 8, 0);
    wrUsize(span + 4, U_FREE[h]);
    U_FREE[h] = @intCast(span - (h << CH_SHIFT) + 1);
    U_LIVE[h] -= 1;
    const class = U_CLASS[h];
    if (U_LIVE[h] == 0) {
        const others = if (was_full) t.avail[class] != 0 else (t.avail[class] != h or U_ANEXT[h] != 0);
        if (others) {
            if (!was_full) availRemove(t, h);
            const n = U_NEXT[h];
            const p = U_PREV[h];
            if (p != 0) U_NEXT[p] = n else t.small_head = n;
            if (n != 0) U_PREV[n] = p;
            t.nsmall[class] -|= 1;
            poolGive(h, U_UNITS[h]);
            CHUNKS_RETIRED += 1;
            return;
        }
    }
    if (was_full) availPush(t, h);
}

// ---------------------------------------------------------------- large pages (TLSF)

inline fn mapping(size: usize) struct { fl: usize, sl: usize } {
    const fl: usize = std.math.log2_int(usize, size);
    const sl = (size >> @intCast(fl - SL_BITS)) & (SL_COUNT - 1);
    return .{ .fl = fl - FL_MIN, .sl = sl };
}

fn tlsfInsert(t: *Task, b: usize) void {
    const m = mapping(rdUsize(b));
    const head = t.free[m.fl][m.sl];
    wrUsize(b + 4, head);
    wrUsize(b + 16, 0);
    if (head != 0) wrUsize(head + 16, b);
    t.free[m.fl][m.sl] = b;
    t.fl_bits |= @as(u32, 1) << @intCast(m.fl);
    t.sl_bits[m.fl] |= @as(u8, 1) << @intCast(m.sl);
}

fn tlsfRemove(t: *Task, b: usize) void {
    const m = mapping(rdUsize(b));
    const next = rdUsize(b + 4);
    const prev = rdUsize(b + 16);
    if (prev != 0) wrUsize(prev + 4, next) else t.free[m.fl][m.sl] = next;
    if (next != 0) wrUsize(next + 16, prev);
    if (t.free[m.fl][m.sl] == 0) {
        t.sl_bits[m.fl] &= ~(@as(u8, 1) << @intCast(m.sl));
        if (t.sl_bits[m.fl] == 0) t.fl_bits &= ~(@as(u32, 1) << @intCast(m.fl));
    }
}

/// A free block of at least `size` (good fit: the next list up), or 0.
fn tlsfFind(t: *Task, size: usize) usize {
    const fl0: usize = std.math.log2_int(usize, size);
    const up = size + (@as(usize, 1) << @intCast(fl0 - SL_BITS)) - 1;
    var m = mapping(up);
    if (m.fl >= FL_COUNT) return 0;
    var sl_map: u32 = t.sl_bits[m.fl] & (~@as(u32, 0) << @intCast(m.sl));
    if (sl_map == 0) {
        const fl_map = if (m.fl + 1 >= 32) 0 else t.fl_bits & (~@as(u32, 0) << @intCast(m.fl + 1));
        if (fl_map == 0) return 0;
        m.fl = @ctz(fl_map);
        sl_map = t.sl_bits[m.fl];
    }
    return t.free[m.fl][@ctz(sl_map)];
}

inline fn isSentinel(b: usize) bool {
    return rdUsize(b) == 16 and spanIsSealed(b);
}

inline fn noteUsed(b: usize) void {
    const h: usize = U_HEAD[b >> CH_SHIFT];
    const end_ = b + rdUsize(b) - (h << CH_SHIFT);
    if (end_ > U_HW[h]) U_HW[h] = @intCast(end_);
}

fn largeAlloc(t: *Task, owner: usize, size: usize) usize {
    var b = tlsfFind(t, size);
    if (b == 0) {
        // A new page from the top: 128 KB << nlarge (to 1 MB), with room for the end sentinel.
        const n = @max(LARGE_BASE << @intCast(@min(t.nlarge, LARGE_STEPS)), (size + 16 + CH - 1) >> CH_SHIFT);
        const first = takeHigh(n);
        if (first == 0) return 0;
        markPage(first, n, KIND_LARGE, t.slot);
        t.nlarge +|= 1;
        U_HW[first] = 0;
        U_NEXT[first] = @intCast(t.large_head);
        t.large_head = @intCast(first);
        const start = first << CH_SHIFT;
        const end_ = start + (n << CH_SHIFT);
        b = start;
        wrUsize(b, end_ - 16 - start);
        wrUsize(b + 8, 0);
        wrUsize(b + 12, 0);
        const s = end_ - 16;
        wrUsize(s, 16);
        wrUsize(s + 4, owner);
        sealSpan(s);
        wrUsize(s + 12, b);
    } else tlsfRemove(t, b);
    const cap = rdUsize(b);
    if (cap - size >= 64) {
        const r = b + size;
        wrUsize(r, cap - size);
        wrUsize(r + 8, 0);
        wrUsize(r + 12, b);
        wrUsize(r + rdUsize(r) + 12, r);
        wrUsize(b, size);
        tlsfInsert(t, r);
    }
    noteUsed(b);
    return b;
}

fn largeFree(t: *Task, b0: usize) void {
    var b = b0;
    wrUsize(b + 8, 0);
    const n = b + rdUsize(b);
    if (!spanIsSealed(n)) {
        tlsfRemove(t, n);
        wrUsize(b, rdUsize(b) + rdUsize(n));
    }
    const p = rdUsize(b + 12);
    if (p != 0 and !spanIsSealed(p)) {
        tlsfRemove(t, p);
        wrUsize(p, rdUsize(p) + rdUsize(b));
        b = p;
    }
    const after = b + rdUsize(b);
    wrUsize(after + 12, b);
    // The whole page is free: give it back.
    if (rdUsize(b + 12) == 0 and isSentinel(after)) {
        const first = b >> CH_SHIFT;
        var prev: u32 = 0;
        var cur = t.large_head;
        while (cur != 0 and cur != first) : (cur = U_NEXT[cur]) prev = cur;
        if (cur == first) {
            if (prev == 0) t.large_head = U_NEXT[first] else U_NEXT[prev] = U_NEXT[first];
            t.nlarge -|= 1;
            U_HW[first] = 0;
            poolGive(first, U_UNITS[first]);
            return;
        }
    }
    tlsfInsert(t, b);
}

/// Grow a large block in place by taking the free block after it.
fn largeGrowInPlace(t: *Task, b: usize, size: usize) bool {
    const cap = rdUsize(b);
    const n = b + cap;
    if (spanIsSealed(n) or cap + rdUsize(n) < size) return false;
    tlsfRemove(t, n);
    const total = cap + rdUsize(n);
    if (total - size >= 64) {
        const r = b + size;
        wrUsize(r, total - size);
        wrUsize(r + 8, 0);
        wrUsize(r + 12, b);
        wrUsize(r + rdUsize(r) + 12, r);
        wrUsize(b, size);
        tlsfInsert(t, r);
    } else {
        wrUsize(b, total);
        wrUsize(b + total + 12, b);
    }
    sealSpan(b);
    noteUsed(b);
    return true;
}

// ---------------------------------------------------------------- huge blocks

fn hugeAlloc(t: *Task, size: usize) usize {
    const n = (size + CH - 1) >> CH_SHIFT;
    const first = takeHigh(n);
    if (first == 0) return 0;
    markPage(first, n, KIND_HUGE, t.slot);
    U_NEXT[first] = @intCast(t.huge_head);
    U_PREV[first] = 0;
    if (t.huge_head != 0) U_PREV[t.huge_head] = @intCast(first);
    t.huge_head = @intCast(first);
    const b = first << CH_SHIFT;
    wrUsize(b, n << CH_SHIFT);
    return b;
}

fn hugeFree(t: *Task, b: usize) void {
    const i = b >> CH_SHIFT;
    wrUsize(b + 8, 0);
    const nx = U_NEXT[i];
    const p = U_PREV[i];
    if (p != 0) U_NEXT[p] = nx else t.huge_head = nx;
    if (nx != 0) U_PREV[nx] = p;
    U_HW[i] = 0;
    poolGive(i, U_UNITS[i]);
}

/// Grow a huge block in place when the units after it are free.
fn hugeGrowInPlace(b: usize, size: usize) bool {
    const i = b >> CH_SHIFT;
    const n: usize = U_UNITS[i];
    const m = (size + CH - 1) >> CH_SHIFT;
    if (i + m > POOL_HI) return false;
    var k = i + n;
    while (k < i + m) : (k += 1) if (!isFree(k)) return false;
    markUsed(i + n, m - n);
    markPage(i, m, KIND_HUGE, U_SLOT[i]);
    wrUsize(b, m << CH_SHIFT);
    sealSpan(b);
    return true;
}

// ---------------------------------------------------------------- API

pub const TRACK_LIVE = @import("build_options").track_live;
pub var LIVE_BYTES: usize = 0;
pub var DEALLOC_MISS: u32 = 0;
pub var ROC_BYTES: usize = 0;

pub fn hostAlloc(length: usize, alignment: usize) usize {
    _ = alignment;
    canary.check();
    const owner = OWNER;
    const t = taskOf(owner);
    const total = alignUp(HEADER_SIZE + length, 16);
    const span = if (classOf(total)) |c| smallAlloc(t, c) else if (total <= LARGE_MAX) largeAlloc(t, owner, total) else hugeAlloc(t, total);
    if (span == 0) return 0;
    const cap = rdUsize(span);
    t.live +%= cap;
    if (TRACK_LIVE) LIVE_BYTES +%= cap;
    wrUsize(span + 4, owner);
    sealSpan(span);
    switch (U_KIND[span >> CH_SHIFT]) {
        KIND_SMALL => wrUsize(span + 12, HEADER_SIZE + length),
        KIND_HUGE => U_HW[span >> CH_SHIFT] = @intCast(HEADER_SIZE + length),
        else => {},
    }
    return span + HEADER_SIZE;
}

fn releaseSpan(span: usize) void {
    const u = span >> CH_SHIFT;
    const slot = U_SLOT[u];
    if (slot != 0 and SLOT_OWNER[slot] == 0) {
        DEALLOC_MISS += 1;
        return;
    }
    const t = &TASKS[slot];
    const cap = rdUsize(span);
    t.live -%= cap;
    if (TRACK_LIVE) LIVE_BYTES -%= cap;
    switch (U_KIND[u]) {
        KIND_SMALL => smallFree(t, span),
        KIND_LARGE => largeFree(t, span),
        else => hugeFree(t, span),
    }
}

inline fn isSpanKind(k: u8) bool {
    return k == KIND_SMALL or k == KIND_LARGE or k == KIND_HUGE;
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const span = spanOf(ptr);
    if (span != 0 and (span >> CH_SHIFT) < MAX_UNITS and isSpanKind(U_KIND[span >> CH_SHIFT])) releaseSpan(span) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    if (ptr == 0) return hostAlloc(new_length, alignment);
    const span = spanOf(ptr);
    if (span == 0) mem.trap();
    const capacity = rdUsize(span);
    const usable = span + capacity - ptr;
    const u = span >> CH_SHIFT;
    if (new_length <= usable) {
        if (U_KIND[u] == KIND_HUGE) U_HW[u] = @intCast(ptr - span + new_length);
        return ptr;
    }
    // Same task: try to grow in place.
    if (SLOT_OWNER[U_SLOT[u]] == OWNER and (U_KIND[u] == KIND_LARGE or U_KIND[u] == KIND_HUGE)) {
        const t = taskOf(OWNER);
        const want = alignUp(new_length + (ptr - span), 16);
        const grew = if (U_KIND[u] == KIND_LARGE) (want <= LARGE_MAX and largeGrowInPlace(t, span, want)) else hugeGrowInPlace(span, want);
        if (grew) {
            if (U_KIND[u] == KIND_HUGE) U_HW[u] = @intCast(ptr - span + new_length);
            const grown = rdUsize(span) - capacity;
            t.live +%= grown;
            if (TRACK_LIVE) LIVE_BYTES +%= grown;
            return ptr;
        }
    }
    const new_ptr = hostAlloc(new_length, alignment);
    if (new_ptr == 0) return 0;
    mem.copyBytes(new_ptr, ptr, usable);
    releaseSpan(span);
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

/// A host block (from `js_alloc`) now belongs to the task that runs: it stays in
/// the host's pages, with the task id in its owner word, so `freeOwner` finds it.
pub fn adopt(ptr: usize) void {
    const span = spanOf(ptr);
    if (span != 0) wrUsize(span + 4, OWNER);
}

/// Walk the host's pages and free the blocks adopted by `owner`.
fn freeAdopted(owner: usize) usize {
    var freed: usize = 0;
    const host = &TASKS[0];
    var h: usize = host.small_head;
    while (h != 0) {
        // Read the next page first: a free can give this page back.
        const next_page = U_NEXT[h];
        const base = h << CH_SHIFT;
        const size = CLASSES[U_CLASS[h]];
        const end_ = base + U_BUMP[h];
        var s = base;
        while (s < end_) : (s += size) {
            if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
                freed += size;
                releaseSpan(s);
                if (U_KIND[h] != KIND_SMALL) break;
            }
        }
        h = next_page;
    }
    var r: usize = host.large_head;
    while (r != 0) {
        const next_run = U_NEXT[r];
        var s = r << CH_SHIFT;
        while (!isSentinel(s)) {
            const cap = rdUsize(s);
            // Read the next span first: a free can join this span with its neighbors.
            const next = s + cap;
            if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
                freed += cap;
                releaseSpan(s);
            }
            s = next;
        }
        r = next_run;
    }
    var g: usize = host.huge_head;
    while (g != 0) {
        const next = U_NEXT[g];
        const s = g << CH_SHIFT;
        if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
            freed += rdUsize(s);
            releaseSpan(s);
        }
        g = next;
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
    for ([_]u32{ t.small_head, t.large_head, t.huge_head }) |head| {
        var p: usize = head;
        while (p != 0) {
            const next = U_NEXT[p];
            U_HW[p] = 0;
            poolGive(p, U_UNITS[p]);
            p = next;
        }
    }
    SLOT_OWNER[t.slot] = 0;
    if (LAST_OWNER == owner) LAST_OWNER = 0;
    t.* = std.mem.zeroes(Task);
    return live;
}

/// Free every span of `owner` after a clean trap.
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
export fn js_alloc(len: usize) usize {
    const owner = OWNER;
    OWNER = 0;
    const p = allocOrTrap(4 + len, 4);
    OWNER = owner;
    wrUsize(p, 1);
    return p + 4;
}

pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
const vtable: std.mem.Allocator.VTable = .{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree };
fn vAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const p = hostAlloc(len, alignment.toByteUnits());
    return if (p == 0) null else @ptrFromInt(p);
}
fn vResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const span = spanOf(@intFromPtr(buf.ptr));
    if (span == 0) return false;
    return new_len <= span + rdUsize(span) - @intFromPtr(buf.ptr);
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
/// Sum of all memory of `owner`: its task record, its small pages up to the bump
/// offset, its large pages up to the used end (and the next free header), and
/// its huge blocks up to the requested end.
pub fn sumTask(owner: usize) u64 {
    const t = taskFind(owner) orelse return 0;
    var acc: u64 = fletcher(@intFromPtr(t), @sizeOf(Task) & ~@as(usize, 15), 1);
    var h: usize = t.small_head;
    while (h != 0) : (h = U_NEXT[h]) {
        const len: usize = U_BUMP[h];
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(h << CH_SHIFT, len, h);
        SUM_BYTES += len;
    }
    var r: usize = t.large_head;
    while (r != 0) : (r = U_NEXT[r]) {
        const len = @min(pageEnd(r), alignUp(@as(usize, U_HW[r]) + 32, 16));
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(r << CH_SHIFT, len, r);
        SUM_BYTES += len;
    }
    var g: usize = t.huge_head;
    while (g != 0) : (g = U_NEXT[g]) {
        const len = alignUp(U_HW[g], 16);
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(g << CH_SHIFT, len, g);
        SUM_BYTES += len;
    }
    return acc;
}

/// Old prototype entry point (the walk version), kept for the host code: mode 2 = no sum.
pub fn sumOwner(owner: usize, mode: u32) u64 {
    return if (mode == 2) 0 else sumTask(owner);
}
