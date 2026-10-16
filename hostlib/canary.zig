//! Stack overflow canary. The stack size is `initial_stack_size` in platform/main.roc.
//! The code does not repeat it: the linker symbol `__data_end` gives the stack floor.

const std = @import("std");
const mem = @import("mem.zig");

/// Linker symbol: the end of the data. In a data-first layout the stack starts here.
extern const __data_end: u8;
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
    // Data first: the stack ends at the end of the data. Stack first: it ends at 0.
    const floor = if (STACK_FIRST) 0 else mem.alignUp(@intFromPtr(&__data_end), 16);
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

/// 4-pre (V1): is `sp`, the stack pointer after a trap in a task, the sign of a stack overflow?
/// `top` is the stack pointer of the task start. A good stack pointer is in [STACK_LIMIT, top].
/// Below the limit: in the canary or past address 0. Above `top`: wrapped under 0 (an out-of-bounds trap).
/// Only for a stack-first layout: nothing is below the stack, so such a trap damaged no data.
pub fn overflowed(sp: usize, top: usize) bool {
    return STACK_FIRST and (sp < STACK_LIMIT or sp > top);
}

/// Trap when the stack is below the limit. The allocator calls this on each allocation.
pub inline fn check() void {
    reserve(0);
}

/// Trap as `check` when fewer than `need` bytes of stack are left above the limit. PLAN.md 8e: a Native op
/// that uses a big frame (zstd, `native.stackNeed`) calls this first, so its frame never reaches the canary.
pub inline fn reserve(need: usize) void {
    var probe: u32 = 0;
    std.mem.doNotOptimizeAway(&probe);
    if (@intFromPtr(&probe) < STACK_LIMIT +| need) {
        @as(*volatile u32, @ptrFromInt(CANARY_BASE)).* = 0;
        // Data first: a frame can skip the canary and write over data, so the trap is not clean.
        if (STACK_FIRST) mem.trapClean() else mem.trap();
    }
}

/// For the sum of constant data (PLAN.md 12d): the canary globals and the canary. `init` writes
/// them, and `repair` writes the same words again.
pub fn sumConst(acc: u64) u64 {
    var a = mem.sumBytes(@intFromPtr(&CANARY_BASE), @sizeOf(usize), acc);
    a = mem.sumBytes(@intFromPtr(&STACK_LIMIT), @sizeOf(usize), a);
    a = mem.sumBytes(@intFromPtr(&STACK_FIRST), 1, a);
    return if (CANARY_BASE == 0) a else mem.sumBytes(CANARY_BASE, CANARY_BYTES, a);
}

fn stack_floor() callconv(.c) usize {
    return CANARY_BASE;
}

/// 1: stack first, one instance can run many requests. 0: not stack-first, JS refuses the module (js/runner.js).
export fn stack_first() u32 {
    return @intFromBool(STACK_FIRST);
}

fn stack_canary_ok() callconv(.c) u32 {
    if (CANARY_BASE == 0) return 1;
    var p = CANARY_BASE;
    while (p < CANARY_BASE + CANARY_BYTES) : (p += 4) {
        if (mem.rd32(p) != CANARY_WORD) return 0;
    }
    return 1;
}

// PLAN.md 7a: test exports, in the bench host only.
comptime {
    if (@import("build_options").bench) {
        @export(&stack_floor, .{ .name = "stack_floor" });
        @export(&stack_canary_ok, .{ .name = "stack_canary_ok" });
    }
}
