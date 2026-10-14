//! Shared host code (allocator, canary, Roc callbacks).
//! A host imports this module and refers to `exports` so that the linker
//! symbols in these files are emitted.

pub const mem = @import("mem.zig");
pub const alloc = @import("alloc.zig");
pub const canary = @import("canary.zig");
pub const roc = @import("roc.zig");
pub const wordbuf = @import("wordbuf.zig");

/// Refer to this from the host so that every export in the shared files is kept.
pub const exports = .{ alloc, canary, roc };

test {
    _ = mem;
    _ = wordbuf;
}
