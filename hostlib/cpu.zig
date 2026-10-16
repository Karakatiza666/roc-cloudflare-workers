//! CPU limit flags of workerd (PLAN.md problem 5). workerd registers an instance that exports
//! these two globals. Each holds the address of a u32 in linear memory (the shim reads
//! `Global.value`), and the runtime writes the u32 from outside of wasm: read it as volatile.

const mem = @import("mem.zig");
const alloc = @import("alloc.zig");

/// The runtime writes SIGXCPU (24) when the CPU time of the request is nearly used up, and 0 to clear it.
/// It also writes 0 at registration, so a 0 after the start shows that the runtime registered the module.
const SIGXCPU: u32 = 24;
/// The runtime writes 1 when it stopped the isolate for going over the CPU limit.
const TERMINATED: u32 = 1;

export var __instance_signal: u32 = 0xFFFF;
export var __instance_terminated: u32 = 0xFFFF;

/// Why the last trap happened, for JS (`trap_cause`).
pub const CAUSE_NONE: u32 = 0;
pub const CAUSE_CPU: u32 = 1;
var CAUSE: u32 = CAUSE_NONE;

inline fn load(p: *u32) u32 {
    return @as(*volatile u32, p).*;
}

/// Clean trap for the task that runs when the CPU signal is set (5b): its pages are freed, the
/// instance stays. A host call from JS (OWNER 0) has no task: no trap.
pub inline fn check() void {
    if (load(&__instance_signal) == SIGXCPU and alloc.OWNER != 0) {
        CAUSE = CAUSE_CPU;
        mem.trapClean();
    }
}

/// The cause of the last trap (1: the CPU signal), then clear it. `handle` clears it too.
export fn trap_cause() u32 {
    const c = CAUSE;
    CAUSE = CAUSE_NONE;
    return c;
}

/// For the global check (PLAN.md 12d).
pub fn causeOk() bool {
    return CAUSE <= CAUSE_CPU;
}

/// The lowest address of the globals of this file with a start value (in `.data`).
pub fn firstData() usize {
    return @min(@intFromPtr(&__instance_signal), @intFromPtr(&__instance_terminated));
}

pub fn clearCause() void {
    CAUSE = CAUSE_NONE;
}
