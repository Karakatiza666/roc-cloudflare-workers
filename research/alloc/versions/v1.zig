//! Prototype: an arena per task, with two islands.
//! Pool: 16 KB chunks above the start heap, a free bitmap, and a table with the
//! owner and kind of each chunk (as mimalloc pages).
//! Small island (span <= 4096): bump allocation in the task's own chunks, with a
//! free list per size class (nginx pool + mimalloc local free list).
//! Large island (span > 4096): TLSF (Masmano et al. 2008) over runs of the task's
//! own chunks, with split and join (boundary tags).
//! Task end: all chunks of the task go back to the pool.
//! Span header (both islands): [capacity @0][owner, or next free @4][capacity ^ magic @8][prev phys (large) @12].
//! A span is free when its seal at @8 does not match.

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
const CH_SHIFT = 14;
const CH: usize = 1 << CH_SHIFT;
const MAX_CHUNKS: usize = (256 << 20) >> CH_SHIFT;

/// The task that runs now. 0: the host (never freed by `freeOwner`).
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

// ---------------------------------------------------------------- pool

const KIND_FREE: u8 = 0;
const KIND_SMALL: u8 = 1;
const KIND_LARGE: u8 = 2;
const KIND_FOREIGN: u8 = 3;
var CHUNK_KIND: [MAX_CHUNKS]u8 = @splat(0);
/// The task slot (index in TASKS) that owns the chunk.
var CHUNK_SLOT: [MAX_CHUNKS]u16 = @splat(0);
/// Small chunks: next chunk of the same task. Large runs: next run of the task (first chunk only).
var CHUNK_NEXT: [MAX_CHUNKS]u16 = @splat(0);
/// Large runs: number of chunks (first chunk only).
var CHUNK_RUN: [MAX_CHUNKS]u16 = @splat(0);
var FREE_BITS: [MAX_CHUNKS / 64]u64 = @splat(0);
/// Chunk indexes [POOL_LO, POOL_HI) are ours or foreign.
var POOL_LO: usize = 0;
var POOL_HI: usize = 0;
pub var CHUNKS_USED: usize = 0;
pub var GROWS: usize = 0;
/// Grow step in chunks (the developer option `growStepBytes`).
pub var GROW_CHUNKS: usize = 4;
/// The smallest run of chunks for the large island.
pub var LARGE_MIN_RUN: usize = 4;
export fn set_large_min_run(n: usize) void {
    LARGE_MIN_RUN = n;
}

inline fn isFree(i: usize) bool {
    return (FREE_BITS[i >> 6] >> @intCast(i & 63)) & 1 == 1;
}
inline fn setFree(i: usize, f: bool) void {
    const bit = @as(u64, 1) << @intCast(i & 63);
    if (f) FREE_BITS[i >> 6] |= bit else FREE_BITS[i >> 6] &= ~bit;
}

fn poolInit() void {
    if (POOL_HI != 0) return;
    const cur = @wasmMemorySize(0) * PAGE;
    POOL_LO = alignUp(cur, CH) >> CH_SHIFT;
    POOL_HI = POOL_LO;
}

/// Grow memory so that `n` more free chunks follow POOL_HI. False on out-of-memory.
fn poolGrow(n: usize) bool {
    const top = @wasmMemorySize(0) * PAGE;
    // Other code (Roc's boxy runtime) grew memory: those pages are not ours.
    if (top > POOL_HI << CH_SHIFT) {
        const hi = alignUp(top, CH) >> CH_SHIFT;
        var i = POOL_HI;
        while (i < hi) : (i += 1) CHUNK_KIND[i] = KIND_FOREIGN;
        POOL_HI = hi;
    }
    const want = @max(n, GROW_CHUNKS);
    if (POOL_HI + want > MAX_CHUNKS) return false;
    const need_end = (POOL_HI + want) << CH_SHIFT;
    const cur = @wasmMemorySize(0) * PAGE;
    if (need_end > cur) {
        const pages = (need_end - cur + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, pages) < 0) return false;
        GROWS += 1;
    }
    var i = POOL_HI;
    while (i < POOL_HI + want) : (i += 1) setFree(i, true);
    POOL_HI += want;
    return true;
}

/// Take a run of `n` free chunks (first fit over the bitmap). 0 on out-of-memory.
fn poolTake(n: usize) usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        var i = POOL_LO;
        var run: usize = 0;
        while (i < POOL_HI) {
            if ((i & 63) == 0 and FREE_BITS[i >> 6] == 0) {
                run = 0;
                i += 64;
                continue;
            }
            if (isFree(i)) {
                run += 1;
                if (run == n) {
                    const first = i + 1 - n;
                    var k = first;
                    while (k <= i) : (k += 1) setFree(k, false);
                    CHUNKS_USED += n;
                    return first;
                }
            } else run = 0;
            i += 1;
        }
        // Grow by what the last free run at the top lacks.
        if (!poolGrow(n)) return 0;
    }
    return 0;
}

fn poolGive(first: usize, n: usize) void {
    var k = first;
    while (k < first + n) : (k += 1) {
        CHUNK_KIND[k] = KIND_FREE;
        CHUNK_SLOT[k] = 0;
        CHUNK_NEXT[k] = 0;
        CHUNK_RUN[k] = 0;
        setFree(k, true);
    }
    CHUNKS_USED -= n;
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
    small_head: u32, // chunk index of the newest small chunk (list via CHUNK_NEXT)
    small_cur: usize,
    small_end: usize,
    large_head: u32, // first chunk of the newest large run (list via CHUNK_NEXT)
    fl_bits: u32,
    live: usize,
    heads: [16]usize,
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

// ---------------------------------------------------------------- small island

fn smallAlloc(t: *Task, class: usize) usize {
    const head = t.heads[class];
    if (head != 0) {
        t.heads[class] = rdUsize(head + 4);
        return head;
    }
    const sized = CLASSES[class];
    if (t.small_cur + sized > t.small_end) {
        // Close the old chunk with a free filler span, so the island stays walkable.
        if (t.small_end > t.small_cur) {
            wrUsize(t.small_cur, t.small_end - t.small_cur);
            wrUsize(t.small_cur + 8, 0);
        }
        const c = poolTake(1);
        if (c == 0) return 0;
        CHUNK_KIND[c] = KIND_SMALL;
        CHUNK_SLOT[c] = @intCast(t.slot);
        CHUNK_NEXT[c] = @intCast(t.small_head);
        t.small_head = @intCast(c);
        t.small_cur = c << CH_SHIFT;
        t.small_end = t.small_cur + CH;
    }
    const s = t.small_cur;
    t.small_cur += sized;
    wrUsize(s, sized);
    return s;
}

// ---------------------------------------------------------------- large island (TLSF)

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

fn largeAlloc(t: *Task, owner: usize, size: usize) usize {
    var b = tlsfFind(t, size);
    if (b == 0) {
        // A new run: at least 4 chunks, room for the block and the end sentinel.
        const n = @max(LARGE_MIN_RUN, (size + 16 + CH - 1) >> CH_SHIFT);
        const first = poolTake(n);
        if (first == 0) return 0;
        var k = first;
        while (k < first + n) : (k += 1) {
            CHUNK_KIND[k] = KIND_LARGE;
            CHUNK_SLOT[k] = @intCast(t.slot);
        }
        CHUNK_RUN[first] = @intCast(n);
        CHUNK_NEXT[first] = @intCast(t.large_head);
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
    // Split when the rest can hold a free block.
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
    // The whole run is free: give it back to the pool.
    if (rdUsize(b + 12) == 0 and isSentinel(after)) {
        const first = b >> CH_SHIFT;
        var prev: u32 = 0;
        var cur = t.large_head;
        while (cur != 0 and cur != first) : (cur = CHUNK_NEXT[cur]) prev = cur;
        if (cur == first) {
            if (prev == 0) t.large_head = CHUNK_NEXT[first] else CHUNK_NEXT[prev] = CHUNK_NEXT[first];
            poolGive(first, CHUNK_RUN[first]);
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
    const span = if (classOf(total)) |c| smallAlloc(t, c) else largeAlloc(t, owner, total);
    if (span == 0) return 0;
    const cap = rdUsize(span);
    t.live +%= cap;
    if (TRACK_LIVE) LIVE_BYTES +%= cap;
    wrUsize(span + 4, owner);
    sealSpan(span);
    if (CHUNK_KIND[span >> CH_SHIFT] == KIND_SMALL) wrUsize(span + 12, HEADER_SIZE + length);
    return span + HEADER_SIZE;
}

fn releaseSpan(span: usize) void {
    const c = span >> CH_SHIFT;
    const slot = CHUNK_SLOT[c];
    if (slot != 0 and SLOT_OWNER[slot] == 0) {
        DEALLOC_MISS += 1;
        return;
    }
    const t = &TASKS[slot];
    const cap = rdUsize(span);
    t.live -%= cap;
    if (TRACK_LIVE) LIVE_BYTES -%= cap;
    if (CHUNK_KIND[c] == KIND_SMALL) {
        wrUsize(span + 8, 0);
        const class = CLASS_UP[cap / 16 - 1];
        wrUsize(span + 4, t.heads[class]);
        t.heads[class] = span;
    } else largeFree(t, span);
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const span = spanOf(ptr);
    if (span != 0 and CHUNK_KIND[span >> CH_SHIFT] != KIND_FREE) releaseSpan(span) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    if (ptr == 0) return hostAlloc(new_length, alignment);
    const span = spanOf(ptr);
    if (span == 0) mem.trap();
    const capacity = rdUsize(span);
    const usable = span + capacity - ptr;
    if (new_length <= usable) return ptr;
    // Large, same task: try to grow in place.
    const c = span >> CH_SHIFT;
    if (CHUNK_KIND[c] == KIND_LARGE and SLOT_OWNER[CHUNK_SLOT[c]] == OWNER) {
        const t = taskOf(OWNER);
        const want = alignUp(new_length + (ptr - span), 16);
        if (largeGrowInPlace(t, span, want)) {
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
/// the host island, with the task id in its owner word, so `freeOwner` finds it.
pub fn adopt(ptr: usize) void {
    const span = spanOf(ptr);
    if (span != 0) wrUsize(span + 4, OWNER);
}

/// Walk the host island and free the blocks adopted by `owner`.
fn freeAdopted(owner: usize) usize {
    var freed: usize = 0;
    const host = &TASKS[0];
    var c = host.small_head;
    while (c != 0) : (c = CHUNK_NEXT[c]) {
        var s = @as(usize, c) << CH_SHIFT;
        const end_ = if (s == (host.small_end - CH)) host.small_cur else s + CH;
        while (s < end_) {
            const cap = rdUsize(s);
            if (cap == 0) break;
            const next = s + cap;
            if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
                freed += cap;
                releaseSpan(s);
            }
            s = next;
        }
    }
    var r = host.large_head;
    while (r != 0) {
        const next_run = CHUNK_NEXT[r];
        var s = @as(usize, r) << CH_SHIFT;
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
    return freed;
}

pub var LEAKED_AT_END: usize = 0;

/// The task ended (or trapped clean): give all its chunks back. Returns its live bytes.
pub fn taskEnd(owner: usize) usize {
    if (owner == 0) return 0;
    const t = taskFind(owner) orelse return 0;
    const live = t.live;
    if (TRACK_LIVE) LIVE_BYTES -%= live;
    var c = t.small_head;
    while (c != 0) {
        const next = CHUNK_NEXT[c];
        poolGive(c, 1);
        c = next;
    }
    var r = t.large_head;
    while (r != 0) {
        const next = CHUNK_NEXT[r];
        poolGive(r, CHUNK_RUN[r]);
        r = next;
    }
    SLOT_OWNER[t.slot] = 0;
    if (LAST_OWNER == owner) LAST_OWNER = 0;
    t.* = std.mem.zeroes(Task);
    return live;
}

/// Free every span of `owner` after a clean trap. Never null: no heap walk is needed.
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
export fn set_grow_chunks(n: usize) void {
    GROW_CHUNKS = n;
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
/// Sum of all memory of `owner`: its chunks (the small island up to the bump
/// pointer) and its task record. No heap walk.
pub fn sumTask(owner: usize) u64 {
    const t = taskFind(owner) orelse return 0;
    var acc: u64 = fletcher(@intFromPtr(t), @sizeOf(Task) & ~@as(usize, 15), 1);
    var c = t.small_head;
    while (c != 0) : (c = CHUNK_NEXT[c]) {
        const s = @as(usize, c) << CH_SHIFT;
        const len = if (s == t.small_end - CH) t.small_cur - s else CH;
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(s, alignUp(len, 16), c);
        SUM_BYTES += len;
    }
    var r = t.large_head;
    while (r != 0) : (r = CHUNK_NEXT[r]) {
        const len = @as(usize, CHUNK_RUN[r]) << CH_SHIFT;
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(@as(usize, r) << CH_SHIFT, len, r);
        SUM_BYTES += len;
    }
    return acc;
}

/// Old prototype entry point (the walk version), kept for the host code: mode 2 = no sum.
pub fn sumOwner(owner: usize, mode: u32) u64 {
    return if (mode == 2) 0 else sumTask(owner);
}
