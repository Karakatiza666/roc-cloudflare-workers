//! Stack overflow canary. Keep STACK_SIZE equal to `--wasm-stack-size` in the build.

const std = @import("std");
const mem = @import("mem.zig");

pub const STACK_SIZE: usize = 1024 * 1024;
const CANARY_MARGIN: usize = 8 * 1024;
const CANARY_BYTES: usize = 4 * 1024;
const CANARY_WORD: u32 = 0x4A6F_79C5;
pub var CANARY_BASE: usize = 0;
pub var STACK_LIMIT: usize = 0;
/// The stack is below all data, so an overflow traps at address 0 and writes over nothing.
pub var STACK_FIRST: bool = false;

pub fn writeStackCanary() void {
    var probe: u32 = 0;
    std.mem.doNotOptimizeAway(&probe);
    const top = @intFromPtr(&probe);
    // A global is in the data area: the stack is first when it is below the data.
    STACK_FIRST = top < @intFromPtr(&STACK_LIMIT);
    // Data first: the stack ends STACK_SIZE below the top. Stack first: it ends at 0.
    const floor = if (STACK_FIRST or top <= STACK_SIZE) 0 else top - STACK_SIZE;
    const base = mem.alignUp(floor + CANARY_MARGIN, 16);
    CANARY_BASE = base;
    STACK_LIMIT = base + CANARY_BYTES;
    var p = base;
    while (p < base + CANARY_BYTES) : (p += 4) mem.wr32(p, CANARY_WORD);
}

/// Write the canary again after a trap the host survives (a task that overflowed).
pub fn repair() void {
    var p = CANARY_BASE;
    if (p == 0) return;
    while (p < CANARY_BASE + CANARY_BYTES) : (p += 4) mem.wr32(p, CANARY_WORD);
}

/// Trap when the stack is below the limit. The allocator calls this on each allocation.
pub inline fn check() void {
    var probe: u32 = 0;
    std.mem.doNotOptimizeAway(&probe);
    if (@intFromPtr(&probe) < STACK_LIMIT) {
        @as(*volatile u32, @ptrFromInt(CANARY_BASE)).* = 0;
        // Data first: a frame can skip the canary and write over data, so the trap is not clean.
        if (STACK_FIRST) mem.trapClean() else mem.trap();
    }
}

export fn stack_floor() usize {
    return CANARY_BASE;
}

/// 1: stack first, one instance can run many requests. 0: JS must use an instance per request.
export fn stack_first() u32 {
    return @intFromBool(STACK_FIRST);
}

export fn stack_canary_ok() u32 {
    if (CANARY_BASE == 0) return 1;
    var p = CANARY_BASE;
    while (p < CANARY_BASE + CANARY_BYTES) : (p += 4) {
        if (mem.rd32(p) != CANARY_WORD) return 0;
    }
    return 1;
}
