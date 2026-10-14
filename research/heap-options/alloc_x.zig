//! Allocator prototypes for H1, H4, H5, H6, H9. Based on hostlib/alloc.zig (owner tags and track_live on).
//! Flags (opts.zig): H1 reclaim walk before a grow, H4 split free spans, H5 footer + doubly linked lists +
//! join at each free (+ lower the top), H6 lower the top at each free (one span, no lists change).
//! One region only (no other code grows memory in the harness).
const opts = @import("opts");
const mem = @import("mem.zig");
const rdUsize = mem.rdUsize;
const wrUsize = mem.wrUsize;
const alignUp = mem.alignUp;

const PAGE: usize = 64 * 1024;
pub var NEXT: usize = 0;
pub var END: usize = 0;
pub var START: usize = 0;
pub var OWNER: usize = 0;
pub var LIVE_BYTES: usize = 0;
pub var GROWS: usize = 0;
pub var STEP_PAGES: usize = 1;
pub var WALKS: usize = 0;
pub var WALK_GAIN: usize = 0;
pub var SPLITS: usize = 0;
pub var JOINS: usize = 0;
pub var TOP_LOWERS: usize = 0;

const DLL = opts.h5;
pub const FOOT: usize = if (opts.h5) 4 else 0;

const CLASSES = [16]usize{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
var FREE_HEADS: [16]usize = @splat(0);
var LARGE_HEAD: usize = 0;
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

const CLASS_SLOTS: usize = 4096 / 16;
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

// ---- free lists (singly linked, or doubly linked with prev @12 when DLL)
inline fn headPtr(cap: usize) *usize {
    return if (cap <= 4096) &FREE_HEADS[CLASS_DOWN[cap / 16 - 1]] else &LARGE_HEAD;
}
fn link(span: usize) void {
    const h = headPtr(rdUsize(span));
    wrUsize(span + 4, h.*);
    if (DLL) {
        wrUsize(span + 12, 0);
        if (h.* != 0) wrUsize(h.* + 12, span);
    }
    h.* = span;
}
fn unlink(span: usize) void {
    const next = rdUsize(span + 4);
    const prev = rdUsize(span + 12);
    if (prev == 0) headPtr(rdUsize(span)).* = next else wrUsize(prev + 4, next);
    if (next != 0) wrUsize(next + 12, prev);
}
inline fn setCap(span: usize, cap: usize) void {
    wrUsize(span, cap);
    if (opts.h5) wrUsize(span + cap - 4, cap);
}
inline fn isFree(span: usize) bool {
    return rdUsize(span) != 0 and rdUsize(span + 8) == 0;
}
/// Make `span` free (not sealed) and put it on a list.
fn putFree(span: usize, cap: usize) void {
    setCap(span, cap);
    wrUsize(span + 8, 0);
    link(span);
}

fn bumpSpan(total: usize) usize {
    if (END == 0) {
        END = @wasmMemorySize(0) * PAGE;
        NEXT = END;
        START = END;
    }
    const start_ = NEXT;
    const end_ = start_ + total;
    if (end_ > END) {
        const need = (end_ - END + PAGE - 1) / PAGE;
        const pages = @max(need, STEP_PAGES);
        if (@wasmMemoryGrow(0, pages) < 0) return 0;
        GROWS += 1;
        END += pages * PAGE;
    }
    NEXT = end_;
    return start_;
}

/// H1: join free neighbors, lower NEXT over free spans at the top, build the lists again.
pub fn reclaimWalk() void {
    WALKS += 1;
    const before = NEXT;
    FREE_HEADS = @splat(0);
    LARGE_HEAD = 0;
    var span = START;
    var run: usize = 0; // start of a run of free spans, or 0
    while (span < NEXT) {
        const cap = rdUsize(span);
        if (isFree(span)) {
            if (run == 0) run = span;
        } else if (run != 0) {
            putFree(run, span - run);
            run = 0;
        }
        span += cap;
    }
    if (run != 0) NEXT = run;
    WALK_GAIN += before - NEXT;
}

fn takeFromLists(total: usize) usize {
    if (classOf(total)) |class| {
        const head = FREE_HEADS[class];
        if (head != 0) {
            if (DLL) unlink(head) else FREE_HEADS[class] = rdUsize(head + 4);
            return head;
        }
        if (opts.h4 == 2) {
            // A span from a larger class, then the large list.
            var c = class + 1;
            while (c < 16) : (c += 1) {
                const h = FREE_HEADS[c];
                if (h != 0) {
                    if (DLL) unlink(h) else FREE_HEADS[c] = rdUsize(h + 4);
                    return h;
                }
            }
        } else return 0;
    }
    var prev: usize = 0;
    var cur = LARGE_HEAD;
    while (cur != 0) {
        if (rdUsize(cur) >= total) {
            if (DLL) unlink(cur) else {
                const next = rdUsize(cur + 4);
                if (prev == 0) LARGE_HEAD = next else wrUsize(prev + 4, next);
            }
            return cur;
        }
        prev = cur;
        cur = rdUsize(cur + 4);
    }
    return 0;
}

fn takeSpan(total0: usize) usize {
    const total = if (classOf(total0)) |c| CLASSES[c] else alignUp(total0, 16);
    var span = takeFromLists(total0);
    if (span == 0 and opts.h1 and NEXT + total > END and (NEXT - START) - LIVE_BYTES >= total) {
        reclaimWalk();
        span = takeFromLists(total0);
    }
    if (span != 0) {
        if (opts.h4 != 0) {
            const cap = rdUsize(span);
            // h4 == 1: split large spans only, and keep the rest large or at least one page of small spans.
            if (cap - total >= (if (opts.h4 == 1) @as(usize, 4096) else 32)) {
                SPLITS += 1;
                setCap(span, total);
                putFree(span + total, cap - total);
            }
        }
    } else {
        span = bumpSpan(total);
        if (span == 0) return 0;
        setCap(span, total);
    }
    sealSpan(span);
    return span;
}

fn releaseSpan(span0: usize) void {
    var span = span0;
    var cap = rdUsize(span);
    LIVE_BYTES -%= cap;
    wrUsize(span + 8, 0);
    if (opts.h5) {
        const nx = span + cap;
        if (nx < NEXT and isFree(nx)) {
            unlink(nx);
            cap += rdUsize(nx);
            JOINS += 1;
        }
        if (span > START) {
            const pc = rdUsize(span - 4);
            const p = span - pc;
            if (isFree(p)) {
                unlink(p);
                span = p;
                cap += pc;
                JOINS += 1;
            }
        }
        setCap(span, cap);
    }
    if ((opts.h5 or opts.h6) and span + cap == NEXT) {
        NEXT = span;
        TOP_LOWERS += 1;
        return;
    }
    link(span);
}

pub fn hostAlloc(length: usize) usize {
    const total = alignUp(HEADER_SIZE + length + FOOT, 16);
    const span = takeSpan(total);
    if (span == 0) return 0;
    LIVE_BYTES +%= rdUsize(span);
    wrUsize(span + 4, OWNER);
    if (!DLL) wrUsize(span + 12, HEADER_SIZE + length);
    return span + HEADER_SIZE;
}
pub fn hostDealloc(ptr: usize) void {
    if (ptr == 0) return;
    const span = spanOf(ptr);
    if (span != 0) releaseSpan(span) else mem.trap();
}
pub fn hostRealloc(ptr: usize, new_length: usize) usize {
    if (ptr == 0) return hostAlloc(new_length);
    const span = spanOf(ptr);
    if (span == 0) mem.trap();
    const usable = span + rdUsize(span) - FOOT - ptr;
    if (new_length <= usable) return ptr;
    const new_ptr = hostAlloc(new_length);
    if (new_ptr == 0) return 0;
    mem.copyBytes(new_ptr, ptr, usable);
    releaseSpan(span);
    return new_ptr;
}
pub fn freeOwner(owner: usize) usize {
    var freed: usize = 0;
    var span = START;
    while (span < NEXT) {
        const capacity = rdUsize(span);
        if (capacity == 0 or capacity % 16 != 0) mem.trap();
        if (spanIsSealed(span) and rdUsize(span + 4) == owner) {
            releaseSpan(span);
            freed += capacity;
        }
        span += capacity;
    }
    return freed;
}
