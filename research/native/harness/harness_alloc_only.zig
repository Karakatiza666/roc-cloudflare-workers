//! Size reference: the same harness with no Native code (the allocator exports only).
const alloc = @import("alloc");
export fn h_task(owner: usize) void {
    alloc.OWNER = owner;
}
export fn h_in(len: usize) usize {
    return alloc.hostAllocFor(0, len, 1);
}
