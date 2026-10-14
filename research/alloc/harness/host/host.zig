//! Bench host: one Roc request handler that waits on JS with JSPI.
//! Variant A (copy off): a fresh instance for each request, no stack copy.
//! Variant B (copy on): one instance for all requests. A wait copies the
//! used shadow stack to the heap, and back at the resume.
//! roc_platform_abi.zig: `roc glue host/ZigGlue.roc host/glue platform/main.roc` (bench/build.sh).

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const lib = @import("hostlib");

comptime {
    _ = lib.exports;
}

pub const panic = std.debug.no_panic;

const mem = lib.mem;
const gpa = lib.alloc.allocator;
const trap = mem.trap;
const RocStr = abi.RocStr;
const Bytes = abi.RocListWith(u8, false);
const AwaitRet = abi.WaitWait;
const ROC_HOST = &lib.roc.RocHostOf(abi.RocHost).host;
const StrOps = lib.roc.StrOf(RocStr);

comptime {
    mem.checkStr(RocStr);
    _ = mem.fieldOff(AwaitRet, "status", u16);
    _ = mem.fieldOff(AwaitRet, "body", Bytes);
}

inline fn slice(s: *const RocStr) []const u8 {
    const sp = mem.strAt(@intFromPtr(s));
    return @as([*]const u8, @ptrFromInt(sp.p))[0..sp.l];
}

/// 1: copy the stack at each wait (variant B). 0: no copy (variant A).
var COPY: bool = false;

export fn init(copy: u32) void {
    lib.canary.writeStackCanary();
    COPY = copy != 0;
}

/// The stack pointer when wasm is idle, while a task runs. 0: no task runs.
var TASK_TOP: usize = 0;
var TASK_WAITING: u32 = 0;
var TASK_SAVED: usize = 0;
var TASK_SAVED_MAX: usize = 0;
/// The most bytes held by waiting copies at one time.
var TASK_SAVED_PEAK: usize = 0;
var TASK_WAITS: u32 = 0;

const Wait = struct { low: usize, top: usize, buf: []u8, out: [2]u32, owner: usize, sum: u64 = 0, epoch: u32 = 0 };
/// 0: no sums. 1: sum at suspend, check at resume only on a suspect instance (after
/// an unclean trap). 2: also check at resume when another task ran in between.
var SUM_MODE: u32 = 0;
/// Set by JS after an unclean trap: each task checks its sum at resume.
var SUSPECT: bool = false;
/// Counts each entry of a task into wasm (a new handle, or a resume).
var RUN_EPOCH: u32 = 0;
var DAMAGED: u32 = 0;
export fn set_suspect(on: u32) void {
    SUSPECT = on != 0;
}
export fn damaged() u32 {
    return DAMAGED;
}
export fn set_sum(m: u32) void {
    SUM_MODE = m;
}
export fn sum_bytes() f64 {
    return @floatFromInt(lib.alloc.SUM_BYTES);
}

/// The last task id. Ids are not reused, so a stale tag never matches a new task.
var TASK_IDS: usize = 0;

inline fn getSP() usize {
    return asm volatile (
        \\.globaltype __stack_pointer, i32
        \\global.get __stack_pointer
        \\local.set %[ret]
        : [ret] "=r" (-> usize),
        :
        : .{ .memory = true });
}

inline fn setSP(v: usize) void {
    asm volatile (
        \\.globaltype __stack_pointer, i32
        \\local.get %[v]
        \\global.set __stack_pointer
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// Copy the stack of the task to the heap, give the stack to other calls.
inline fn waitBegin() *Wait {
    const top = TASK_TOP;
    if (top == 0) trap();
    const low = getSP();
    // The Wait record is in the host island: JS writes `out` while the task waits.
    const owner = lib.alloc.OWNER;
    lib.alloc.OWNER = 0;
    const w = gpa.create(Wait) catch trap();
    lib.alloc.OWNER = owner;
    const buf = gpa.alloc(u8, top - low) catch trap();
    @memcpy(buf, @as([*]const u8, @ptrFromInt(low))[0..buf.len]);
    w.* = .{ .low = low, .top = top, .buf = buf, .out = .{ 0, 0 }, .owner = lib.alloc.OWNER };
    if (SUM_MODE != 0) w.sum = lib.alloc.sumTask(owner);
    w.epoch = RUN_EPOCH;
    TASK_TOP = 0;
    lib.alloc.OWNER = 0;
    TASK_WAITING += 1;
    TASK_SAVED += buf.len;
    if (buf.len > TASK_SAVED_MAX) TASK_SAVED_MAX = buf.len;
    if (TASK_SAVED > TASK_SAVED_PEAK) TASK_SAVED_PEAK = TASK_SAVED;
    TASK_WAITS += 1;
    setSP(top);
    return w;
}

/// The stack is idle (at TOP): put the task back on it.
inline fn waitEnd(w: *Wait) [2]u32 {
    if (getSP() != w.top) trap();
    if (SUM_MODE != 0 and (SUSPECT or (SUM_MODE == 2 and w.epoch != RUN_EPOCH))) {
        if (lib.alloc.sumTask(w.owner) != w.sum) {
            DAMAGED += 1;
            trap();
        }
    }
    RUN_EPOCH +%= 1;
    setSP(w.low);
    @memcpy(@as([*]u8, @ptrFromInt(w.low))[0..w.buf.len], w.buf);
    TASK_TOP = w.top;
    lib.alloc.OWNER = w.owner;
    TASK_WAITING -= 1;
    TASK_SAVED -= w.buf.len;
    const out = w.out;
    gpa.free(w.buf);
    gpa.destroy(w);
    return out;
}

/// kind, number, text a, text b, bytes c, address of [body ptr, body len]. Returns the status.
extern "env" fn js_wait(kind: u32, num: f64, ap: usize, al: usize, bp: usize, bl: usize, cp: usize, cl: usize, out: usize) u32;

export fn roc_wait(kind: u32, num: u64, a: RocStr, b: RocStr, c: Bytes) callconv(.c) AwaitRet {
    const as = slice(&a);
    const bs = slice(&b);
    const cs = c.items();
    var out: [2]u32 = .{ 0, 0 };
    var status: u32 = 0;
    if (kind == 99) mem.wr32(0xFFFF_FFF0, 1);
    if (kind == 98) @trap();
    if (kind == 97) {
        // A wild write: random words in the heap, then a trap that is not clean.
        const top = @wasmMemorySize(0) * 65536;
        const base = @intFromPtr(&SP_AT_ABORT);
        var i: u32 = 0;
        while (i < WILD_WORDS) : (i += 1) {
            WILD_SEED = WILD_SEED *% 1103515245 +% 12345;
            const wa = base + (WILD_SEED % (top - base - 8)) & ~@as(usize, 3);
            mem.wr32(wa, WILD_SEED);
        }
        @trap();
    }
    if (COPY) {
        const w = waitBegin();
        status = js_wait(kind, @floatFromInt(num), @intFromPtr(as.ptr), as.len, @intFromPtr(bs.ptr), bs.len, @intFromPtr(cs.ptr), cs.len, @intFromPtr(&w.out));
        out = waitEnd(w);
    } else {
        status = js_wait(kind, @floatFromInt(num), @intFromPtr(as.ptr), as.len, @intFromPtr(bs.ptr), bs.len, @intFromPtr(cs.ptr), cs.len, @intFromPtr(&out));
    }
    a.decref(ROC_HOST);
    b.decref(ROC_HOST);
    c.decref(ROC_HOST);
    return .{ .status = @truncate(status), .body = bytesFrom(out[0], out[1]) };
}

/// A List(U8) over the js_alloc block at `ptr`, which it takes.
fn bytesFrom(ptr: usize, len: usize) Bytes {
    if (len == 0) {
        if (ptr != 0) lib.alloc.hostDealloc(ptr - 4);
        return .{ .elements_ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    }
    lib.alloc.adopt(ptr);
    return .{ .elements_ptr = @ptrFromInt(ptr), .length = len, .capacity_or_alloc_ptr = len << 1 };
}

/// Run the handler on the request in the js_alloc block at `p` (taken).
/// Returns a heap block [len u32][bytes] for JS; JS frees it with `res_free`.
/// No frame of its own: TOP is the stack pointer of the JS call.
export fn handle(p: usize, l: usize) usize {
    TASK_IDS +%= 1;
    if (TASK_IDS == 0) TASK_IDS = 1;
    lib.alloc.OWNER = TASK_IDS;
    lib.alloc.adopt(p);
    RUN_EPOCH +%= 1;
    TASK_TOP = getSP();
    const r = @call(.never_inline, handleImpl, .{ p, l });
    TASK_TOP = 0;
    // The task ended: its chunks go back to the pool.
    _ = lib.alloc.taskEnd(lib.alloc.OWNER);
    lib.alloc.OWNER = 0;
    return r;
}

fn handleImpl(p: usize, l: usize) usize {
    const res = abi.roc_handle(StrOps.fromParts(p, l));
    const s = slice(&res);
    // The response outlives the task: it goes in the host island.
    const owner = lib.alloc.OWNER;
    lib.alloc.OWNER = 0;
    const blk = lib.alloc.allocOrTrap(4 + s.len, 4);
    lib.alloc.OWNER = owner;
    mem.wrUsize(blk, s.len);
    mem.copyBytes(blk + 4, @intFromPtr(s.ptr), s.len);
    res.decref(ROC_HOST);
    return blk;
}

export fn res_free(p: usize) void {
    lib.alloc.hostDealloc(p);
}

/// After a trap in a task: give the stack back, write the canary again, free
/// the spans of the task. Returns the bytes freed, or maxInt when the trap was
/// not clean (`mem.TRAP_CLEAN`) or the heap could not be walked: then the
/// caller must drop the instance.
/// No frame of its own: a frame epilogue would write the old stack pointer back
/// after `setSP`. So the free runs in a call, before `setSP`.
var SP_AT_ABORT: usize = 0;
var WILD_SEED: u32 = 1;
var WILD_WORDS: u32 = 16;
export fn set_wild(seed: u32, words: u32) void {
    WILD_SEED = seed;
    WILD_WORDS = words;
}
export fn sp_at_abort() usize {
    return SP_AT_ABORT;
}
export fn canary_base() usize {
    return lib.canary.CANARY_BASE;
}
export fn task_abort() usize {
    SP_AT_ABORT = getSP();
    const freed = @call(.never_inline, abortFree, .{});
    if (TASK_TOP != 0) setSP(TASK_TOP);
    TASK_TOP = 0;
    @call(.never_inline, lib.canary.repair, .{});
    return freed;
}

fn abortFree() usize {
    const clean = mem.TRAP_CLEAN;
    mem.TRAP_CLEAN = false;
    const freed = if (clean) lib.alloc.freeOwner(lib.alloc.OWNER) else null;
    lib.alloc.OWNER = 0;
    return freed orelse std.math.maxInt(usize);
}

/// Overhead bench: `n` rounds of `k` allocations of `size` bytes, then their frees.
export fn alloc_bench(n: u32, k: u32, size: usize) u32 {
    var ptrs: [256]usize = undefined;
    var sum: u32 = 0;
    for (0..n) |_| {
        for (0..k) |i| ptrs[i] = lib.alloc.allocOrTrap(size, 8);
        for (0..k) |i| {
            sum +%= @truncate(ptrs[i]);
            lib.alloc.hostDealloc(ptrs[i]);
        }
    }
    return sum;
}

/// Walk bench: keep `count` live spans of `size` bytes under owner `tag` (0: free them).
var FILL: [65536]usize = undefined;
var FILLED: usize = 0;
export fn heap_fill(count: usize, size: usize, tag: usize) void {
    for (0..FILLED) |i| lib.alloc.hostDealloc(FILL[i]);
    FILLED = 0;
    const saved = lib.alloc.OWNER;
    lib.alloc.OWNER = tag;
    for (0..@min(count, FILL.len)) |i| {
        FILL[i] = lib.alloc.allocOrTrap(size, 8);
        FILLED += 1;
    }
    lib.alloc.OWNER = saved;
}
/// One heap walk for an owner that has no spans. Returns the bytes freed (0), or maxInt.
export fn walk_bench(owner: usize) usize {
    return lib.alloc.freeOwner(owner) orelse std.math.maxInt(usize);
}

export fn task_waiting() u32 {
    return TASK_WAITING;
}
export fn task_saved() usize {
    return TASK_SAVED;
}
export fn task_saved_max() usize {
    return TASK_SAVED_MAX;
}
export fn task_saved_peak() usize {
    return TASK_SAVED_PEAK;
}
export fn task_waits() u32 {
    return TASK_WAITS;
}
/// Zero the copy counters, before a measured run.
export fn stats_reset() void {
    TASK_SAVED_MAX = 0;
    TASK_SAVED_PEAK = 0;
    TASK_WAITS = 0;
}
/// The copy work of `iters` waits of `len` bytes alone: alloc, copy out, copy back, free.
/// It copies the bytes at [4096, 4096 + len), inside the stack area.
export fn copy_bench(len: usize, iters: u32) u32 {
    var sum: u32 = 0;
    const src: [*]u8 = @ptrFromInt(4096);
    for (0..iters) |_| {
        const w = gpa.create(Wait) catch trap();
        const buf = gpa.alloc(u8, len) catch trap();
        @memcpy(buf, src[0..len]);
        w.* = .{ .low = 4096, .top = 4096 + len, .buf = buf, .out = .{ 0, 0 }, .owner = 0 };
        std.mem.doNotOptimizeAway(w);
        @memcpy(src[0..len], w.buf);
        sum +%= buf[len / 2];
        gpa.free(w.buf);
        gpa.destroy(w);
    }
    return sum;
}

/// Turn the stack copy on or off. Off is safe only with one request at a time.
export fn set_copy(on: u32) void {
    COPY = on != 0;
}
export fn live_bytes() usize {
    return lib.alloc.LIVE_BYTES;
}
