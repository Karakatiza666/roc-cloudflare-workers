//! Foreign allocator adapter (research/alloc/foreign/README.md): a different allocator behind the API of
//! hostlib/alloc.zig, for upper-bound tests with the sums off (shim `resumeCheck: "off"`) and the global check off.
//! No task pages: no task sums (`sumTask` gives a constant), no free of a task's blocks at a trap,
//! and `checkTables` always passes. Not for production.
//! `gen.sh` makes one copy for each backend: it replaces the line `const BACKEND ...` below.
const std = @import("std");
const mem = @import("mem.zig");
const canary = @import("canary.zig");
const cpu = @import("cpu.zig");
const wrUsize = mem.wrUsize;

const BACKEND: Backend = .bump;
const Backend = enum { bump, bumpr, zig, dl, em, mi, tl };

const PAGE: usize = 64 * 1024;
const MAX_MEM: usize = 128 << 20;
pub var OWNER: usize = 0;
pub const TASK_SLOTS: u32 = 254;
pub var ROC_BYTES: usize = 0;
pub var FAIL_AT: u32 = 0;
pub var ALLOCS: u32 = 0;
pub const TRACK_LIVE = @import("build_options").track_live;
pub var LIVE_BYTES: usize = 0;
pub var LIVE_PEAK: usize = 0;
var WIN_PEAK: usize = 0;
var LIVE_BLOCKS: usize = 0;
var N_ALLOC: u32 = 0;
var N_FREE: u32 = 0;
var N_REALLOC: u32 = 0;
var N_BYTES: u32 = 0;
var N_GROW: u32 = 0;
var RESETS: u32 = 0;
/// A global with a start value: `firstData` (the host sums the constant data below the first such global).
var FIRST_DATA: usize = 0x5A5A_5A5A;
var GROW_STEP: usize = PAGE;

export fn set_grow_step(bytes: usize) void {
    mem.enter();
    GROW_STEP = std.math.clamp(bytes, PAGE, MAX_MEM);
}
export fn set_free_mark(k: usize) void {
    _ = k;
    mem.enter();
}
export fn double_frees() u32 {
    return 0;
}

// ---------------------------------------------------------------- memory (one break, as sbrk)

const ASK_JS = @import("build_options").ask_js;
extern "env" fn js_grow(pages: u32) u32;
var BRK: usize = 0;
var HEAP_LO: usize = 0;

/// Move the break by `n` bytes (n >= 0) and give the old break, or maxInt on out-of-memory (sbrk).
pub fn brkMove(n: usize) usize {
    if (BRK == 0) {
        BRK = @wasmMemorySize(0) * PAGE;
        HEAP_LO = BRK;
    }
    const old = BRK;
    const end_ = @wasmMemorySize(0) * PAGE;
    if (BRK + n > end_) {
        const need = (BRK + n - end_ + PAGE - 1) / PAGE;
        var pages = @max(need, GROW_STEP / PAGE);
        if (end_ + pages * PAGE > MAX_MEM) pages = need;
        if (end_ + pages * PAGE > MAX_MEM) return std.math.maxInt(usize);
        if (ASK_JS and js_grow(@intCast(pages)) == 0) {
            if (need >= pages or js_grow(@intCast(need)) == 0) return std.math.maxInt(usize);
            pages = need;
        }
        if (@wasmMemoryGrow(0, pages) < 0) return std.math.maxInt(usize);
        N_GROW +%= 1;
    }
    BRK += n;
    return old;
}

/// For the C backends (dlmalloc MORECORE, emmalloc).
export fn sbrk(n: isize) callconv(.c) usize {
    if (n < 0) return std.math.maxInt(usize);
    return brkMove(@intCast(n));
}

// ---------------------------------------------------------------- backends

/// The C backends: research/alloc/foreign/<name>.c, linked into the host object (gen.sh).
extern fn fa_malloc(len: usize) callconv(.c) usize;
extern fn fa_free(p: usize) callconv(.c) void;
extern fn fa_realloc(p: usize, len: usize) callconv(.c) usize;
extern fn fa_usable(p: usize) callconv(.c) usize;

/// Header of the Zig and bump backends: 16 B before the block, the length in word 0 (the frees do not give it).
const HDR: usize = 16;
inline fn hdrLen(p: usize) usize {
    return mem.rdUsize(p - HDR);
}

/// bump, bumpr: the end of the last block (it can grow in place).
var LAST: usize = 0;

fn bAlloc(owner: usize, len: usize) usize {
    switch (BACKEND) {
        .bump, .bumpr => {
            const n = std.mem.alignForward(usize, len, 16) + HDR;
            const b = brkMove(n);
            if (b == std.math.maxInt(usize)) return 0;
            wrUsize(b, len);
            LAST = b + HDR;
            return b + HDR;
        },
        .zig => {
            const s = std.heap.wasm_allocator.rawAlloc(len + HDR, .@"16", 0) orelse return 0;
            const b = @intFromPtr(s);
            wrUsize(b, len);
            return b + HDR;
        },
        .tl => return tl.alloc(owner, len),
        else => return fa_malloc(len),
    }
}
fn bFree(p: usize) void {
    switch (BACKEND) {
        .bump => {},
        .bumpr => if (LIVE_BLOCKS == 0) {
            BRK = HEAP_LO;
            LAST = 0;
            RESETS += 1;
        },
        .zig => {
            const b: [*]u8 = @ptrFromInt(p - HDR);
            std.heap.wasm_allocator.rawFree(b[0 .. hdrLen(p) + HDR], .@"16", 0);
        },
        .tl => tl.free(p),
        else => fa_free(p),
    }
}
fn bUsable(p: usize) usize {
    return switch (BACKEND) {
        .bump, .bumpr, .zig => hdrLen(p),
        .tl => tl.usable(p),
        else => fa_usable(p),
    };
}
/// Realloc to `len` (> 0). 0 on out-of-memory (the old block stays).
fn bRealloc(owner: usize, p: usize, len: usize) usize {
    switch (BACKEND) {
        .bump, .bumpr => {
            const old = hdrLen(p);
            if (len <= std.mem.alignForward(usize, old, 16)) {
                wrUsize(p - HDR, len);
                return p;
            }
            if (p == LAST and BRK == p + std.mem.alignForward(usize, old, 16)) {
                const more = std.mem.alignForward(usize, len, 16) - std.mem.alignForward(usize, old, 16);
                if (brkMove(more) == std.math.maxInt(usize)) return 0;
                wrUsize(p - HDR, len);
                return p;
            }
            const q = bAlloc(owner, len);
            if (q == 0) return 0;
            mem.copyBytes(q, p, old);
            return q;
        },
        .zig => {
            const old = hdrLen(p);
            const b: [*]u8 = @ptrFromInt(p - HDR);
            if (std.heap.wasm_allocator.rawResize(b[0 .. old + HDR], .@"16", len + HDR, 0)) {
                wrUsize(p - HDR, len);
                return p;
            }
            const q = bAlloc(owner, len);
            if (q == 0) return 0;
            mem.copyBytes(q, p, @min(old, len));
            std.heap.wasm_allocator.rawFree(b[0 .. old + HDR], .@"16", 0);
            return q;
        },
        .tl => return tl.realloc(owner, p, len),
        else => return fa_realloc(p, len),
    }
}

const tl = if (BACKEND == .tl) @import("fa_tl.zig") else struct {
    fn alloc(_: usize, _: usize) usize {
        return 0;
    }
    fn free(_: usize) void {}
    fn usable(_: usize) usize {
        return 0;
    }
    fn realloc(_: usize, _: usize, _: usize) usize {
        return 0;
    }
    fn taskEnd(_: usize) void {}
};

// ---------------------------------------------------------------- API (as hostlib/alloc.zig)

inline fn liveAdd(n: usize) void {
    if (!TRACK_LIVE) return;
    LIVE_BYTES +%= n;
    if (LIVE_BYTES > WIN_PEAK) {
        WIN_PEAK = LIVE_BYTES;
        if (LIVE_BYTES > LIVE_PEAK) LIVE_PEAK = LIVE_BYTES;
    }
}

pub fn hostAlloc(length: usize, alignment: usize) usize {
    return hostAllocFor(OWNER, length, alignment);
}
pub fn hostAllocFor(owner: usize, length: usize, alignment: usize) usize {
    _ = alignment;
    canary.check();
    N_ALLOC +%= 1;
    N_BYTES +%= @truncate(length);
    const p = bAlloc(owner, @max(length, 1));
    if (p == 0) return 0;
    LIVE_BLOCKS += 1;
    liveAdd(bUsable(p));
    return p;
}
/// JS blocks (`js_alloc`): [JS_MAGIC][~start][unused][Roc refcount][bytes]. The host and Roc free them by a pointer
/// to the bytes or to the refcount (hostlib/roc.zig), not by the start: this finds the start (0: not a JS block).
/// The second word holds the address, so a stale or chance match is not taken; a free clears the mark.
const JS_MAGIC: u32 = 0x4A53_B10C;
const JS_HDR: usize = 16;
inline fn jsStart(f: usize) usize {
    if (f < 64) return 0;
    if (mem.rd32(f - 16) == JS_MAGIC and mem.rd32(f - 12) == ~@as(u32, @intCast(f - 16))) return f - 16;
    if (mem.rd32(f - 12) == JS_MAGIC and mem.rd32(f - 8) == ~@as(u32, @intCast(f - 12))) return f - 12;
    return 0;
}

pub fn hostDealloc(ptr0: usize) void {
    if (ptr0 == 0) return;
    N_FREE +%= 1;
    var ptr = ptr0;
    const js = jsStart(ptr);
    if (js != 0) {
        wrUsize(js, 0);
        ptr = js;
    }
    if (TRACK_LIVE) LIVE_BYTES -%= bUsable(ptr);
    LIVE_BLOCKS -%= 1;
    bFree(ptr);
}
pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    return hostReallocFor(OWNER, ptr, new_length, alignment);
}
pub fn hostReallocFor(owner: usize, ptr: usize, new_length: usize, alignment: usize) usize {
    if (ptr == 0) return hostAllocFor(owner, new_length, alignment);
    const js = jsStart(ptr);
    if (js != 0) {
        // A JS block that grows: a new block of the backend, the bytes from `ptr` on, then the free.
        const room = js + JS_HDR + mem.rdUsize(js + 8) - ptr;
        const q = hostAllocFor(owner, new_length, alignment);
        if (q == 0) return 0;
        mem.copyBytes(q, ptr, @min(room, new_length));
        hostDealloc(ptr);
        return q;
    }
    N_REALLOC +%= 1;
    const before = bUsable(ptr);
    const p = bRealloc(owner, ptr, @max(new_length, 1));
    if (p == 0) return 0;
    if (p != ptr) N_BYTES +%= @truncate(new_length);
    if (TRACK_LIVE) LIVE_BYTES -%= before;
    liveAdd(bUsable(p));
    return p;
}

pub inline fn allocOrTrap(length: usize, alignment: usize) usize {
    const p = hostAlloc(length, alignment);
    if (p == 0) cpu.oom();
    return p;
}
pub inline fn reallocOrTrap(ptr: usize, new_length: usize, alignment: usize) usize {
    const p = hostRealloc(ptr, new_length, alignment);
    if (p == 0) cpu.oom();
    return p;
}
pub inline fn allocHostOrTrap(length: usize, alignment: usize) usize {
    const p = hostAllocFor(0, length, alignment);
    if (p == 0) cpu.oom();
    return p;
}
pub inline fn reallocHostOrTrap(ptr: usize, new_length: usize, alignment: usize) usize {
    const p = hostReallocFor(0, ptr, new_length, alignment);
    if (p == 0) cpu.oom();
    return p;
}

pub export fn roc_alloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    cpu.check();
    const p = hostAlloc(length, alignment);
    if (p == 0) cpu.oom();
    ROC_BYTES += length;
    return @ptrFromInt(p);
}
export fn roc_dealloc(ptr: ?*anyopaque, alignment: usize) callconv(.c) void {
    _ = alignment;
    canary.check();
    hostDealloc(@intFromPtr(ptr));
}
pub export fn roc_realloc(ptr: ?*anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    cpu.check();
    const p = hostRealloc(@intFromPtr(ptr), new_length, alignment);
    if (p == 0) cpu.oom();
    if (p != @intFromPtr(ptr)) ROC_BYTES += new_length;
    return @ptrFromInt(p);
}

/// No owner words: an adopted JS block is freed by the task (Roc frees it), not by a walk.
pub fn adopt(ptr: usize) void {
    _ = ptr;
}
pub fn taskEnd(owner: usize) usize {
    if (owner == 0) return 0;
    @import("native/native.zig").endTask(allocator, owner, .forget);
    if (BACKEND == .tl) tl.taskEnd(owner);
    return 0;
}
pub fn taskDone(owner: usize) usize {
    return taskEnd(owner);
}
/// A trap leaks the task's blocks here (no task pages; `tl` frees them). The tests have no traps.
pub fn freeOwner(owner: usize) ?usize {
    return taskEnd(owner);
}

export fn dealloc_miss() u32 {
    return 0;
}
export fn heap_used() usize {
    return if (BRK == 0) 0 else @wasmMemorySize(0) * PAGE - HEAP_LO;
}
export fn heap_bytes() usize {
    return heap_used();
}
export fn live_peak() usize {
    return LIVE_PEAK;
}
export fn alloc_stat(i: u32) usize {
    return switch (i) {
        0 => N_ALLOC,
        1 => N_FREE,
        2 => N_REALLOC,
        3 => N_BYTES,
        4 => N_GROW,
        5 => WIN_PEAK,
        else => 0,
    };
}
export fn alloc_window() void {
    WIN_PEAK = LIVE_BYTES;
}
export fn reclaim_walks() u32 {
    return 0;
}
export fn reclaim_bytes() usize {
    return 0;
}
export fn leaked_at_end() usize {
    return 0;
}
/// bumpr: the resets of the break (all blocks free).
export fn idle_resets() u32 {
    return RESETS;
}
export fn idle_reset_bytes() usize {
    return 0;
}
pub fn idleReset() bool {
    return false;
}

pub export fn js_alloc(len: usize) usize {
    mem.enter();
    const p = hostAllocFor(0, JS_HDR + len, 8);
    if (p == 0) return 0;
    wrUsize(p, JS_MAGIC);
    wrUsize(p + 4, ~@as(u32, @intCast(p)));
    wrUsize(p + 8, len);
    wrUsize(p + 12, 1);
    return p + JS_HDR;
}

pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
const vtable: std.mem.Allocator.VTable = .{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree };
fn vAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const p = hostAlloc(len, alignment.toByteUnits());
    return if (p == 0) null else @ptrFromInt(p);
}
fn vResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len <= bUsable(@intFromPtr(buf.ptr));
}
fn vRemap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    const p = hostRealloc(@intFromPtr(buf.ptr), new_len, alignment.toByteUnits());
    return if (p == 0) null else @ptrFromInt(p);
}
fn vFree(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    hostDealloc(@intFromPtr(buf.ptr));
}

// ---------------------------------------------------------------- sums and checks: off

pub const SUM_K: u64 = 0x9E37_79B9_7F4A_7C15;
pub fn sumTask(owner: usize) u64 {
    _ = owner;
    return 1;
}
pub fn jsBlockOk(p: usize, len: usize) bool {
    return if (p == 0) len == 0 else p >= 8;
}
pub fn adoptedBlock(owner: usize) usize {
    _ = owner;
    return 0;
}
pub fn markInit() void {}
pub fn sumConst(acc: u64) u64 {
    return acc;
}
pub fn firstData() usize {
    return @intFromPtr(&FIRST_DATA);
}
pub fn checkTables() u32 {
    return 0;
}
pub fn hostBlockOk(p: usize, len: usize) bool {
    _ = p;
    _ = len;
    return true;
}
pub fn slotBlockOk(p: usize, slot: usize, len: usize) bool {
    _ = p;
    _ = slot;
    _ = len;
    return true;
}
pub fn slotOf(owner: usize) ?usize {
    return if (owner == 0) null else 1;
}
pub fn slotsInUse() usize {
    return 0;
}
pub fn breakTable(kind: u32, arg: usize) u32 {
    _ = kind;
    _ = arg;
    return 0;
}
