//! Not an allocator: the replay cost with no allocator work (the loop, the record reads, the
//! touch of each block). Every block is the same static buffer; free, task end and sums do nothing.
//! Replay time minus this time is the allocator time. Research tool only (scripts/replay.mjs).
const std = @import("std");
pub var OWNER: usize = 0;
pub var LIVE_BYTES: usize = 0;
var BUF: [(1 << 20) + 64]u8 align(16) = undefined;
pub fn allocOrTrap(length: usize, alignment: usize) usize {
    _ = length;
    _ = alignment;
    return @intFromPtr(&BUF);
}
pub fn reallocOrTrap(ptr: usize, new_length: usize, alignment: usize) usize {
    _ = new_length;
    _ = alignment;
    // Keep the offset the trace gives (ptr - off stays the block start).
    return ptr;
}
pub fn hostDealloc(ptr: usize) void {
    _ = ptr;
}
pub fn taskEnd(owner: usize) usize {
    _ = owner;
    return 0;
}
pub fn sumTask(owner: usize) u64 {
    return owner;
}
pub fn adopt(ptr: usize) void {
    _ = ptr;
}
pub fn freeOwner(owner: usize) ?usize {
    _ = owner;
    return 0;
}
