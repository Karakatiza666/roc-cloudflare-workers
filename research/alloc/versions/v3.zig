//! Prototype v3: Hoard pages on a binary buddy pool.
//! Pool: 4 KB pages above the start heap. A binary buddy (Knuth 1973) gives
//! blocks of 2^k pages. A freed block joins its buddy (index XOR 2^k) at once.
//! Small (span <= 4096): per task, one size class per page, with a free list and
//! a live count per page (Hoard superblocks, mimalloc pages). An empty page goes
//! back to the buddy pool, except the last page with room in its class.
//! Large (span > 4096): one buddy block per span, owned by the task. The tail
//! pages after the span go back at once (as Linux alloc_pages_exact).
//! Task end: all pages of the task go back to the pool.
//! Span header: [capacity @0][owner, or next free @4][capacity ^ magic @8][requested end @12].
//! A span is free when its seal at @8 does not match.

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
const CH_SHIFT: comptime_int = @import("build_options").ch_shift;
const CH: usize = 1 << CH_SHIFT;
/// The heap limit is 128 MB, so page indexes fit in u16.
const MAX_CHUNKS: usize = (128 << 20) >> CH_SHIFT;
const MAX_ORDER: u8 = @intCast(std.math.log2_int(usize, MAX_CHUNKS) - 1);

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

// ---------------------------------------------------------------- pool (binary buddy)

const KIND_NONE: u8 = 0; // not a block head (inside a block, or not ours)
const KIND_SMALL: u8 = 1;
const KIND_LARGE: u8 = 2;
const KIND_FOREIGN: u8 = 3;
const KIND_FREE: u8 = 4; // head of a free buddy block
var CHUNK_KIND: [MAX_CHUNKS]u8 = @splat(0);
/// Block heads: the block is 2^order pages.
var CHUNK_ORDER: [MAX_CHUNKS]u8 = @splat(0);
/// Large blocks: the number of pages (the tail of the buddy block goes back).
var CHUNK_PAGES: [MAX_CHUNKS]u16 = @splat(0);
/// The task slot (index in TASKS) that owns the page.
var CHUNK_SLOT: [MAX_CHUNKS]u8 = @splat(0);
/// Doubly linked lists: a task's small pages, a task's large blocks, or a buddy free list.
var CHUNK_NEXT: [MAX_CHUNKS]u16 = @splat(0);
var CHUNK_PREV: [MAX_CHUNKS]u16 = @splat(0);
// Small pages: one size class each, with their own free list and live count.
var CHUNK_CLASS: [MAX_CHUNKS]u8 = @splat(0);
var CHUNK_LIVE: [MAX_CHUNKS]u16 = @splat(0);
/// Offset of the bump pointer in the page: blocks below it were handed out once.
var CHUNK_BUMP: [MAX_CHUNKS]u16 = @splat(0);
/// The free list: offset + 1 of the first free block in the page, 0 when empty.
var CHUNK_FREE: [MAX_CHUNKS]u16 = @splat(0);
/// Small pages of a task and class that have room (doubly linked).
var CHUNK_ANEXT: [MAX_CHUNKS]u16 = @splat(0);
var CHUNK_APREV: [MAX_CHUNKS]u16 = @splat(0);
pub var CHUNKS_RETIRED: usize = 0;
/// Buddy free lists, one per order, and a bit per non-empty list.
var FREE_HEAD: [MAX_ORDER + 1]u16 = @splat(0);
var ORDER_BITS: u32 = 0;
/// Page indexes [POOL_LO, POOL_HI) are ours or foreign.
var POOL_LO: usize = 0;
var POOL_HI: usize = 0;
pub var CHUNKS_USED: usize = 0;
pub var GROWS: usize = 0;
/// Grow step in pages (the developer option `growStepBytes`).
pub var GROW_CHUNKS: usize = (64 * 1024) >> CH_SHIFT;
export fn set_large_min_run(n: usize) void {
    _ = n;
}

fn freePush(i: usize, k: u8) void {
    const head = FREE_HEAD[k];
    CHUNK_KIND[i] = KIND_FREE;
    CHUNK_ORDER[i] = k;
    CHUNK_NEXT[i] = head;
    CHUNK_PREV[i] = 0;
    if (head != 0) CHUNK_PREV[head] = @intCast(i);
    FREE_HEAD[k] = @intCast(i);
    ORDER_BITS |= @as(u32, 1) << @intCast(k);
}

fn freeRemove(i: usize) void {
    const k = CHUNK_ORDER[i];
    const n = CHUNK_NEXT[i];
    const p = CHUNK_PREV[i];
    if (p != 0) CHUNK_NEXT[p] = n else FREE_HEAD[k] = n;
    if (n != 0) CHUNK_PREV[n] = p;
    if (FREE_HEAD[k] == 0) ORDER_BITS &= ~(@as(u32, 1) << @intCast(k));
    CHUNK_KIND[i] = KIND_NONE;
    CHUNK_NEXT[i] = 0;
    CHUNK_PREV[i] = 0;
}

inline fn isFreeBlock(i: usize, k: u8) bool {
    return i >= POOL_LO and i < POOL_HI and CHUNK_KIND[i] == KIND_FREE and CHUNK_ORDER[i] == k;
}

/// Free the block [i, i + 2^k): join with free buddies while there are some.
fn buddyFree(first: usize, k0: u8) void {
    var i = first;
    var k = k0;
    CHUNK_KIND[i] = KIND_NONE;
    while (k < MAX_ORDER) {
        const b = i ^ (@as(usize, 1) << @intCast(k));
        if (!isFreeBlock(b, k)) break;
        freeRemove(b);
        i = @min(i, b);
        k += 1;
    }
    freePush(i, k);
}

/// Free the pages [a, a + n) as the largest aligned blocks.
fn freeRange(a0: usize, n0: usize) void {
    var a = a0;
    var n = n0;
    while (n > 0) {
        var o: u8 = 0;
        while (o < MAX_ORDER and a % (@as(usize, 2) << @intCast(o)) == 0 and (@as(usize, 2) << @intCast(o)) <= n) o += 1;
        buddyFree(a, o);
        a += @as(usize, 1) << @intCast(o);
        n -= @as(usize, 1) << @intCast(o);
    }
}

/// The head of the free block that holds page `p`, or 0.
fn freeBlockOf(p: usize) usize {
    var j: u8 = 0;
    while (j <= MAX_ORDER) : (j += 1) {
        const h = p & ~((@as(usize, 1) << @intCast(j)) - 1);
        if (isFreeBlock(h, j)) return h;
    }
    return 0;
}

/// Take the pages [a, a + n) if all are free. The parts of free blocks outside the range stay free.
fn takeRange(a: usize, n: usize) bool {
    var p = a;
    while (p < a + n) {
        const h = freeBlockOf(p);
        if (h == 0) return false;
        p = h + (@as(usize, 1) << @intCast(CHUNK_ORDER[h]));
    }
    p = a;
    while (p < a + n) {
        const h = freeBlockOf(p);
        const end_ = h + (@as(usize, 1) << @intCast(CHUNK_ORDER[h]));
        freeRemove(h);
        if (h < a) freeRange(h, a - h);
        if (end_ > a + n) freeRange(a + n, end_ - (a + n));
        p = end_;
    }
    CHUNKS_USED += n;
    return true;
}

fn poolInit() void {
    if (POOL_HI != 0) return;
    const cur = @wasmMemorySize(0) * PAGE;
    POOL_LO = alignUp(cur, CH) >> CH_SHIFT;
    POOL_HI = POOL_LO;
}

/// Grow memory so that a free block of order `k` exists. False on out-of-memory.
fn poolGrow(k: u8) bool {
    const top = @wasmMemorySize(0) * PAGE;
    // Other code (Roc's boxy runtime) grew memory: those pages are not ours.
    if (top > POOL_HI << CH_SHIFT) {
        const hi = alignUp(top, CH) >> CH_SHIFT;
        var i = POOL_HI;
        while (i < hi) : (i += 1) CHUNK_KIND[i] = KIND_FOREIGN;
        POOL_HI = hi;
    }
    const size = @as(usize, 1) << @intCast(k);
    const end_ = @max(alignUp(POOL_HI, size) + size, POOL_HI + GROW_CHUNKS);
    if (end_ > MAX_CHUNKS) return false;
    const cur = @wasmMemorySize(0) * PAGE;
    if (end_ << CH_SHIFT > cur) {
        const pages = ((end_ << CH_SHIFT) - cur + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, pages) < 0) return false;
        GROWS += 1;
    }
    const old = POOL_HI;
    POOL_HI = end_;
    freeRange(old, end_ - old);
    return true;
}

/// Take a block of 2^k pages. 0 on out-of-memory.
fn poolTake(k: u8) usize {
    poolInit();
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        const avail = ORDER_BITS & (~@as(u32, 0) << @intCast(k));
        if (avail != 0) {
            var j: u8 = @intCast(@ctz(avail));
            // Address order (Johnstone and Wilson 1998): the lowest block of the smallest order that fits.
            var i: usize = FREE_HEAD[j];
            var c: usize = CHUNK_NEXT[i];
            while (c != 0) : (c = CHUNK_NEXT[c]) i = @min(i, c);
            freeRemove(i);
            // Split: keep the low half, free the high half.
            while (j > k) {
                j -= 1;
                freePush(i + (@as(usize, 1) << @intCast(j)), j);
            }
            CHUNK_ORDER[i] = k;
            CHUNKS_USED += @as(usize, 1) << @intCast(k);
            return i;
        }
        if (!poolGrow(k)) return 0;
    }
    return 0;
}

fn poolGive(i: usize, k: u8) void {
    CHUNK_SLOT[i] = 0;
    CHUNK_ANEXT[i] = 0;
    CHUNK_APREV[i] = 0;
    CHUNKS_USED -= @as(usize, 1) << @intCast(k);
    buddyFree(i, k);
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

const Task = extern struct {
    owner: usize,
    slot: u32,
    small_head: u32, // all small pages (CHUNK_NEXT, CHUNK_PREV)
    large_head: u32, // all large blocks (CHUNK_NEXT, CHUNK_PREV)
    live: usize,
    avail: [16]u16, // per class: the pages with room (CHUNK_ANEXT, CHUNK_APREV)
    _pad: [12]u8,
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

inline fn chunkFull(c: usize) bool {
    return CHUNK_FREE[c] == 0 and @as(usize, CHUNK_BUMP[c]) + CLASSES[CHUNK_CLASS[c]] > CH;
}

fn availPush(t: *Task, c: usize) void {
    const class = CHUNK_CLASS[c];
    const head = t.avail[class];
    CHUNK_ANEXT[c] = head;
    CHUNK_APREV[c] = 0;
    if (head != 0) CHUNK_APREV[head] = @intCast(c);
    t.avail[class] = @intCast(c);
}

fn availRemove(t: *Task, c: usize) void {
    const n = CHUNK_ANEXT[c];
    const p = CHUNK_APREV[c];
    if (p != 0) CHUNK_ANEXT[p] = n else t.avail[CHUNK_CLASS[c]] = n;
    if (n != 0) CHUNK_APREV[n] = p;
    CHUNK_ANEXT[c] = 0;
    CHUNK_APREV[c] = 0;
}

fn smallAlloc(t: *Task, class: usize) usize {
    var c: usize = t.avail[class];
    if (c == 0) {
        c = poolTake(0);
        if (c == 0) return 0;
        CHUNK_KIND[c] = KIND_SMALL;
        CHUNK_SLOT[c] = @intCast(t.slot);
        CHUNK_CLASS[c] = @intCast(class);
        CHUNK_LIVE[c] = 0;
        CHUNK_BUMP[c] = 0;
        CHUNK_FREE[c] = 0;
        CHUNK_NEXT[c] = @intCast(t.small_head);
        CHUNK_PREV[c] = 0;
        if (t.small_head != 0) CHUNK_PREV[t.small_head] = @intCast(c);
        t.small_head = @intCast(c);
        availPush(t, c);
    }
    var s: usize = CHUNK_FREE[c];
    if (s != 0) {
        s += (c << CH_SHIFT) - 1;
        CHUNK_FREE[c] = @intCast(rdUsize(s + 4));
    } else {
        s = (c << CH_SHIFT) + CHUNK_BUMP[c];
        CHUNK_BUMP[c] += @intCast(CLASSES[class]);
    }
    CHUNK_LIVE[c] += 1;
    if (chunkFull(c)) availRemove(t, c);
    wrUsize(s, CLASSES[class]);
    return s;
}

/// Give an empty small chunk back to the pool, unless it is the last chunk with room in its class.
fn smallFree(t: *Task, span: usize) void {
    const c = span >> CH_SHIFT;
    const was_full = chunkFull(c);
    wrUsize(span + 8, 0);
    wrUsize(span + 4, CHUNK_FREE[c]);
    CHUNK_FREE[c] = @intCast(span - (c << CH_SHIFT) + 1);
    CHUNK_LIVE[c] -= 1;
    const class = CHUNK_CLASS[c];
    if (CHUNK_LIVE[c] == 0) {
        // Keep one empty chunk per class: a loop that frees and allocates does not give and take.
        const others = if (was_full) t.avail[class] != 0 else (t.avail[class] != c or CHUNK_ANEXT[c] != 0);
        if (others) {
            if (!was_full) availRemove(t, c);
            const n = CHUNK_NEXT[c];
            const p = CHUNK_PREV[c];
            if (p != 0) CHUNK_NEXT[p] = n else t.small_head = n;
            if (n != 0) CHUNK_PREV[n] = p;
            poolGive(c, 0);
            CHUNKS_RETIRED += 1;
            return;
        }
    }
    if (was_full) availPush(t, c);
}

// ---------------------------------------------------------------- large (buddy blocks)

inline fn pagesFor(total: usize) usize {
    return (total + CH - 1) >> CH_SHIFT;
}

/// A buddy block of 2^k pages, with the tail after `n` pages given back (as Linux alloc_pages_exact).
fn largeAlloc(t: *Task, size: usize) usize {
    const n = pagesFor(size);
    const k: u8 = @intCast(std.math.log2_int_ceil(usize, n));
    const i = poolTake(k);
    if (i == 0) return 0;
    const full = @as(usize, 1) << @intCast(k);
    if (full > n) {
        CHUNKS_USED -= full - n;
        freeRange(i + n, full - n);
    }
    CHUNK_KIND[i] = KIND_LARGE;
    CHUNK_PAGES[i] = @intCast(n);
    CHUNK_SLOT[i] = @intCast(t.slot);
    CHUNK_NEXT[i] = @intCast(t.large_head);
    CHUNK_PREV[i] = 0;
    if (t.large_head != 0) CHUNK_PREV[t.large_head] = @intCast(i);
    t.large_head = @intCast(i);
    const b = i << CH_SHIFT;
    wrUsize(b, n << CH_SHIFT);
    return b;
}

fn largeFree(t: *Task, b: usize) void {
    const i = b >> CH_SHIFT;
    wrUsize(b + 8, 0);
    const nx = CHUNK_NEXT[i];
    const p = CHUNK_PREV[i];
    if (p != 0) CHUNK_NEXT[p] = nx else t.large_head = nx;
    if (nx != 0) CHUNK_PREV[nx] = p;
    const n = CHUNK_PAGES[i];
    CHUNK_SLOT[i] = 0;
    CHUNK_PAGES[i] = 0;
    CHUNK_KIND[i] = KIND_NONE;
    CHUNKS_USED -= n;
    freeRange(i, n);
}

/// Grow a large block in place when the pages after it are free.
fn largeGrowInPlace(b: usize, size: usize) bool {
    const i = b >> CH_SHIFT;
    const n: usize = CHUNK_PAGES[i];
    const m = pagesFor(size);
    if (i + m > POOL_HI or !takeRange(i + n, m - n)) return false;
    CHUNK_PAGES[i] = @intCast(m);
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
    const span = if (classOf(total)) |c| smallAlloc(t, c) else largeAlloc(t, total);
    if (span == 0) return 0;
    const cap = rdUsize(span);
    t.live +%= cap;
    if (TRACK_LIVE) LIVE_BYTES +%= cap;
    wrUsize(span + 4, owner);
    sealSpan(span);
    wrUsize(span + 12, HEADER_SIZE + length);
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
    if (CHUNK_KIND[c] == KIND_SMALL) smallFree(t, span) else largeFree(t, span);
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const span = spanOf(ptr);
    if (span != 0 and (CHUNK_KIND[span >> CH_SHIFT] == KIND_SMALL or CHUNK_KIND[span >> CH_SHIFT] == KIND_LARGE)) releaseSpan(span) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    if (ptr == 0) return hostAlloc(new_length, alignment);
    const span = spanOf(ptr);
    if (span == 0) mem.trap();
    const capacity = rdUsize(span);
    const usable = span + capacity - ptr;
    if (new_length <= usable) {
        wrUsize(span + 12, ptr - span + new_length);
        return ptr;
    }
    // Large, same task: try to grow in place.
    const c = span >> CH_SHIFT;
    if (CHUNK_KIND[c] == KIND_LARGE and SLOT_OWNER[CHUNK_SLOT[c]] == OWNER) {
        const t = taskOf(OWNER);
        const want = alignUp(new_length + (ptr - span), 16);
        if (largeGrowInPlace(span, want)) {
            wrUsize(span + 12, ptr - span + new_length);
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
    var c: usize = host.small_head;
    while (c != 0) {
        // Read the next chunk first: a free can give this chunk back.
        const next_chunk = CHUNK_NEXT[c];
        const base = c << CH_SHIFT;
        const size = CLASSES[CHUNK_CLASS[c]];
        const end_ = base + CHUNK_BUMP[c];
        var s = base;
        while (s < end_) : (s += size) {
            if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
                freed += size;
                releaseSpan(s);
                if (CHUNK_KIND[c] == KIND_FREE) break;
            }
        }
        c = next_chunk;
    }
    var r = host.large_head;
    while (r != 0) {
        const next = CHUNK_NEXT[r];
        const s = @as(usize, r) << CH_SHIFT;
        if (spanIsSealed(s) and rdUsize(s + 4) == owner) {
            freed += rdUsize(s);
            releaseSpan(s);
        }
        r = next;
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
        poolGive(c, 0);
        c = next;
    }
    var r = t.large_head;
    while (r != 0) {
        const next = CHUNK_NEXT[r];
        const n = CHUNK_PAGES[r];
        CHUNK_KIND[r] = KIND_NONE;
        CHUNK_SLOT[r] = 0;
        CHUNK_PAGES[r] = 0;
        CHUNKS_USED -= n;
        freeRange(r, n);
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
        const len: usize = CHUNK_BUMP[c];
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(@as(usize, c) << CH_SHIFT, len, c);
        SUM_BYTES += len;
    }
    var r = t.large_head;
    while (r != 0) : (r = CHUNK_NEXT[r]) {
        const len = alignUp(rdUsize((@as(usize, r) << CH_SHIFT) + 12), 16);
        acc = acc *% 0x9E37_79B9_7F4A_7C15 +% fletcher(@as(usize, r) << CH_SHIFT, len, r);
        SUM_BYTES += len;
    }
    return acc;
}

/// Old prototype entry point (the walk version), kept for the host code: mode 2 = no sum.
pub fn sumOwner(owner: usize, mode: u32) u64 {
    return if (mode == 2) 0 else sumTask(owner);
}
