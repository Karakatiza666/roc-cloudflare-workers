//! Shared host code (allocator, canary, Roc callbacks).
//! A host imports this module and refers to `exports` so that the linker
//! symbols in these files are emitted.

/// PLAN.md 7a: the bench host (`zig build -Dbench=true`) has the test exports, the production host has not.
pub const BENCH = @import("build_options").bench;

pub const mem = @import("mem.zig");
pub const alloc = @import("alloc.zig");
pub const canary = @import("canary.zig");
pub const roc = @import("roc.zig");
pub const cpu = @import("cpu.zig");
pub const wordbuf = @import("wordbuf.zig");
/// PLAN.md 8e: the Native ops (`native!`) and the cleanup hook `native.endTask` (`alloc.taskEnd`).
pub const native = @import("native/native.zig");

/// Refer to this from the host so that every export in the shared files is kept.
pub const exports = .{ alloc, canary, roc, cpu };

test {
    _ = mem;
    _ = wordbuf;
}
