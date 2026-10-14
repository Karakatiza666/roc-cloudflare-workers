//! Research copy v0: the allocator of hostlib/alloc.zig (one shared heap), plus
//! `taskEnd` (no-op) and a sum by heap walk for the harness.
//! Allocator: size-class free lists over bump-grown linear memory.
//! Span header: [capacity @0][free-list next @4, or owner when live][capacity ^ magic @8][requested end @12].

const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
var NEXT: usize = 0;
var END: usize = 0;

/// Owner tags (build option `owner_tag`): each live span holds the task that allocated it.
const OWNER_TAG = @import("build_options").owner_tag;
/// The task that runs now. 0: the host (never freed by `freeOwner`).
pub var OWNER: usize = 0;
/// Bump regions [start, end) that hold spans back to back. A new region starts
/// when other code grew memory (see `bumpSpan`). The last one ends at NEXT.
const MAX_REGIONS = 64;
var REGION_START: [MAX_REGIONS]usize = @splat(0);
var REGION_END: [MAX_REGIONS]usize = @splat(0);
var REGIONS: usize = 0;
/// More regions than MAX_REGIONS: `freeOwner` cannot walk the heap.
var REGIONS_LOST: bool = false;

const CLASSES = [16]usize{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
var FREE_HEADS: [16]usize = @splat(0);
var LARGE_HEAD: usize = 0;

/// Fixed 16-byte header on 16-aligned spans. A known compiler bug passes
/// `roc_dealloc` a pointer up to 12 bytes too high, and a fixed header still
/// recovers the span from it (see `spanOf`).
pub const HEADER_SIZE: usize = 16;
const SPAN_MAGIC: usize = 0xC0DE_5AFE;

inline fn sealSpan(span: usize) void {
    wrUsize(span + 8, rdUsize(span) ^ SPAN_MAGIC);
}

pub inline fn spanIsSealed(span: usize) bool {
    const capacity = rdUsize(span);
    return capacity != 0 and capacity % 16 == 0 and rdUsize(span + 8) == capacity ^ SPAN_MAGIC;
}

/// The span for any pointer `roc_dealloc` receives, or 0 when none is sealed.
pub inline fn spanOf(ptr: usize) usize {
    if (ptr < 32) return 0;
    const candidate = (ptr - 16) & ~@as(usize, 15);
    return if (spanIsSealed(candidate)) candidate else 0;
}

const CLASS_SLOTS: usize = 4096 / 16;
/// CLASS_UP[t/16 - 1]: smallest class whose spans hold `t` bytes.
const CLASS_UP: [CLASS_SLOTS]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [CLASS_SLOTS]u8 = undefined;
    for (0..CLASS_SLOTS) |s| {
        const total = (s + 1) * 16;
        var i: usize = 0;
        while (CLASSES[i] < total) i += 1;
        t[s] = i;
    }
    break :blk t;
};
/// CLASS_DOWN[t/16 - 1]: largest class whose spans fit within `t` bytes.
const CLASS_DOWN: [CLASS_SLOTS]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [CLASS_SLOTS]u8 = undefined;
    for (0..CLASS_SLOTS) |s| {
        const total = (s + 1) * 16;
        var c: usize = 0;
        for (CLASSES, 0..) |cls, i| {
            if (cls <= total) c = i;
        }
        t[s] = c;
    }
    break :blk t;
};

inline fn classOf(total: usize) ?usize {
    if (total == 0 or total > 4096) return null;
    return CLASS_UP[(total + 15) / 16 - 1];
}

/// Bump a fresh 16-aligned span off the top of the heap. 0 on out-of-memory.
fn bumpSpan(total: usize) usize {
    // Roc's boxy runtime also grows memory. When the top of memory is no
    // longer END, restart the bump region above those pages.
    const cur = @wasmMemorySize(0) * PAGE;
    if (cur != END) {
        if (OWNER_TAG) {
            if (REGIONS > 0) REGION_END[REGIONS - 1] = NEXT;
            if (REGIONS == MAX_REGIONS) REGIONS_LOST = true else REGIONS += 1;
            REGION_START[REGIONS - 1] = alignUp(cur, 16);
        }
        NEXT = alignUp(cur, 16);
        END = cur;
    }
    const start_ = NEXT;
    const end_ = start_ + total;
    if (end_ > END) {
        const pages = (end_ - END + PAGE - 1) / PAGE;
        if (@wasmMemoryGrow(0, pages) < 0) return 0;
        END += pages * PAGE;
    }
    NEXT = end_;
    return start_;
}

fn takeSpan(total: usize) usize {
    var span: usize = 0;
    if (classOf(total)) |class| {
        const head = FREE_HEADS[class];
        if (head != 0) {
            FREE_HEADS[class] = rdUsize(head + 4);
            span = head;
        } else {
            const sized = CLASSES[class];
            const s = bumpSpan(sized);
            if (s == 0) return 0;
            wrUsize(s, sized);
            span = s;
        }
    } else {
        // Large: first fit over the large list.
        var prev: usize = 0;
        var cur = LARGE_HEAD;
        while (true) {
            if (cur == 0) {
                const sized = alignUp(total, 16);
                const s = bumpSpan(sized);
                if (s == 0) return 0;
                wrUsize(s, sized);
                span = s;
                break;
            }
            if (rdUsize(cur) >= total) {
                const next = rdUsize(cur + 4);
                if (prev == 0) LARGE_HEAD = next else wrUsize(prev + 4, next);
                span = cur;
                break;
            }
            prev = cur;
            cur = rdUsize(cur + 4);
        }
    }
    sealSpan(span);
    return span;
}

fn releaseSpan(span: usize) void {
    const total = rdUsize(span);
    // Check host: a free span is not sealed, so the capture check does not walk stale pointers into it.
    // Owner tags: a free span is not sealed, so `freeOwner` skips it.
    if (TRACK_LIVE) LIVE_BYTES -%= total;
    if (TRACK_LIVE or OWNER_TAG) wrUsize(span + 8, 0);
    if (classOf(total) != null) {
        const class = CLASS_DOWN[total / 16 - 1];
        wrUsize(span + 4, FREE_HEADS[class]);
        FREE_HEADS[class] = span;
    } else {
        wrUsize(span + 4, LARGE_HEAD);
        LARGE_HEAD = span;
    }
}

pub fn hostAlloc(length: usize, alignment: usize) usize {
    _ = alignment;
    // Stack overflow check at allocation time (see canary.zig).
    canary.check();
    const total = alignUp(HEADER_SIZE + length, 16);
    const span = takeSpan(total);
    if (span == 0) return 0;
    if (TRACK_LIVE) LIVE_BYTES +%= rdUsize(span);
    if (OWNER_TAG) wrUsize(span + 4, OWNER);
    // Requested end, read by the Joy host's `lazySame` to compare thunk captures.
    wrUsize(span + 12, HEADER_SIZE + length);
    return span + HEADER_SIZE;
}

pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const span = spanOf(ptr);
    if (span != 0) releaseSpan(span) else DEALLOC_MISS += 1;
}

pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    if (ptr == 0) return hostAlloc(new_length, alignment);
    const span = spanOf(ptr);
    if (span == 0) mem.trap();
    const capacity = rdUsize(span);
    const usable = span + capacity - ptr;
    if (new_length <= usable) return ptr;
    const new_ptr = hostAlloc(new_length, alignment);
    if (new_ptr == 0) return 0;
    mem.copyBytes(new_ptr, ptr, usable);
    releaseSpan(span);
    return new_ptr;
}

/// Allocate or trap. Host-internal buffers never continue on out-of-memory.
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

/// Bytes Roc asked for since the start: allocations, and reallocations that
/// move. A host reads it around a call to see whether the call copied the model.
pub var ROC_BYTES: usize = 0;

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

/// Bytes of the spans in use (headers included). A leak check reads it before and after add and remove cycles.
/// Counted only when `track_live` is set (the Shpadoinkle check host, build.zig). Else it stays 0.
pub var LIVE_BYTES: usize = 0;
const TRACK_LIVE = @import("build_options").track_live;

/// Give a live block to the task that runs now (a block JS filled for it).
pub fn adopt(ptr: usize) void {
    if (!OWNER_TAG) return;
    const span = spanOf(ptr);
    if (span != 0) wrUsize(span + 4, OWNER);
}

/// Free every live span of `owner` (a task that trapped). Returns the bytes
/// freed, or null when the heap cannot be walked (the caller drops the instance).
pub fn freeOwner(owner: usize) ?usize {
    if (!OWNER_TAG or REGIONS_LOST) return null;
    if (owner == 0) return 0;
    if (REGIONS > 0) REGION_END[REGIONS - 1] = NEXT;
    var freed: usize = 0;
    for (0..REGIONS) |r| {
        var span = REGION_START[r];
        const end_ = REGION_END[r];
        while (span < end_) {
            const capacity = rdUsize(span);
            if (capacity == 0 or capacity % 16 != 0 or capacity > end_ - span) return null;
            if (spanIsSealed(span) and rdUsize(span + 4) == owner) {
                releaseSpan(span);
                freed += capacity;
            }
            span += capacity;
        }
    }
    return freed;
}

pub var DEALLOC_MISS: u32 = 0;
export fn dealloc_miss() u32 {
    return DEALLOC_MISS;
}
export fn heap_used() usize {
    return NEXT;
}

/// Allocate `len` bytes for JS to write into, behind a refcount word of 1.
/// Owned by the host (0) until a task adopts it: JS can call this after a trap,
/// while OWNER still names the dead task.
export fn js_alloc(len: usize) usize {
    const owner = OWNER;
    OWNER = 0;
    const p = allocOrTrap(4 + len, 4);
    OWNER = owner;
    wrUsize(p, 1);
    return p + 4;
}

/// A `std.mem.Allocator` over this heap, for host-internal arrays.
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: std.mem.Allocator.VTable = .{
    .alloc = vAlloc,
    .resize = vResize,
    .remap = vRemap,
    .free = vFree,
};

fn vAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // Spans are 16-aligned and the header is 16 bytes, so data is 16-aligned.
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

// ---------------------------------------------------------------- harness additions

/// The shared heap has no per-task memory to give back.
pub fn taskEnd(owner: usize) usize {
    _ = owner;
    return 0;
}

/// Fletcher sum (2 lanes of u64, s1 += w, s2 += s1) over [p, p + len). p and len are 16-aligned.
pub fn fletcher(p: usize, len: usize, seed: u64) u64 {
    const V = @Vector(2, u64);
    var s1: V = @splat(seed);
    var s2: V = @splat(0);
    const v = @as([*]const V, @ptrFromInt(p))[0 .. len / 16];
    for (v) |w| {
        s1 +%= w;
        s2 +%= s1;
    }
    return s1[0] ^ (s2[0] *% 3) ^ (s1[1] *% 5) ^ (s2[1] *% 7);
}

pub var SUM_BYTES: u64 = 0;
/// Sum of the spans of `owner`: a walk of the whole heap.
pub fn sumTask(owner: usize) u64 {
    if (REGIONS > 0) REGION_END[REGIONS - 1] = NEXT;
    var acc: u64 = 0;
    for (0..REGIONS) |r| {
        var span = REGION_START[r];
        const end_ = REGION_END[r];
        while (span < end_) {
            const capacity = rdUsize(span);
            if (capacity == 0) break;
            if (spanIsSealed(span) and rdUsize(span + 4) == owner) {
                acc +%= fletcher(span, capacity, span);
                SUM_BYTES += capacity;
            }
            span += capacity;
        }
    }
    return acc;
}
