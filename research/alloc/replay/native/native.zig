//! Port replay stub of hostlib/native/native.zig: no Native handles.
pub const EndMode = enum { free, forget };
pub fn endTask(a: anytype, owner: usize, mode: EndMode) void {
    _ = a;
    _ = owner;
    _ = mode;
}
