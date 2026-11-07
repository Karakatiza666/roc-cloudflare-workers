//! Port replay stub of hostlib/cpu.zig: no CPU signal; out of memory is a clean trap.
const mem = @import("mem.zig");
pub inline fn check() void {}
pub fn oom() noreturn {
    mem.trapClean();
}
