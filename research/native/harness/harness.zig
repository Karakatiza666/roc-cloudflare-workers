//! wasm32 harness of the Native ops with the real allocator (hostlib/alloc.zig): the memory of a task is
//! tagged with its owner, so `freeOwner` frees it. Node (run.mjs) drives it. Not part of the platform.

const alloc = @import("alloc");
const native = @import("native");

var res: native.Result = .{ .status = 0, .bytes = &.{}, .owned = false };

/// The task that runs (the owner tag of new blocks).
export fn h_task(owner: usize) void {
    alloc.OWNER = owner;
}
/// A block of the host (owner 0) for input bytes.
export fn h_in(len: usize) usize {
    return alloc.hostAllocFor(0, len, 1);
}
export fn h_free(p: usize) void {
    alloc.hostDealloc(p);
}
/// One op for the task that runs. The result stays until `h_res_release`.
export fn h_call(op: u32, ptr: usize, len: usize) u32 {
    const in: [*]const u8 = @ptrFromInt(ptr);
    res = native.call(alloc.allocator, alloc.OWNER, op, in[0..len]);
    return res.status;
}
export fn h_res_ptr() usize {
    return @intFromPtr(res.bytes.ptr);
}
export fn h_res_len() usize {
    return res.bytes.len;
}
export fn h_res_release() void {
    res.release(alloc.allocator);
    res = .{ .status = 0, .bytes = &.{}, .owned = false };
}
/// The task ended by a trap or a cancel: the hook, then the allocator frees the owner. Returns the bytes freed.
export fn h_end_trap(owner: usize) usize {
    native.endTask(alloc.allocator, owner, .forget);
    const n = alloc.freeOwner(owner) orelse 0;
    alloc.OWNER = 0;
    return n;
}
/// The task ended by its return: the hook, then `taskDone` (the bytes that it still held count as a leak).
export fn h_end_done(owner: usize) usize {
    native.endTask(alloc.allocator, owner, .forget);
    const n = alloc.taskDone(owner);
    alloc.OWNER = 0;
    return n;
}
export fn h_in_use(owner: usize) usize {
    return native.inUse(if (owner == 0) null else owner);
}
export fn h_live() usize {
    return alloc.LIVE_BYTES;
}
export fn h_peak() usize {
    return alloc.LIVE_PEAK;
}
export fn h_peak_reset() void {
    alloc.LIVE_PEAK = alloc.LIVE_BYTES;
}
export fn h_miss() u32 {
    return alloc.DEALLOC_MISS;
}
export fn h_check() u32 {
    return alloc.checkTables();
}
/// A local's address: about the stack pointer at this call.
export fn h_sp() usize {
    var x: u32 = 0;
    const p = @intFromPtr(&x);
    asm volatile ("" : : [p] "r" (p) : .{ .memory = true });
    return p;
}
