//! Replay a trace of allocator calls (scripts/trace.mjs) against one version.
//! JS copies records into REC and calls `run`; scripts/replay.mjs times it.
const std = @import("std");
const alloc = @import("alloc.zig");

comptime {
    _ = alloc;
}

const MAX_IDS = 1 << 20;
var PTRS: [MAX_IDS]u32 = undefined;
var REC: [1 << 16][4]u32 = undefined;
var PEAK: usize = 0;
var SUM_ACC: u64 = 0;
/// 0: no sums. 1: a sum when a task waits. 2: also a check when it resumes
/// (its first call after the wait), as the host does when the instance is suspect.
var SUM_MODE: u32 = 1;
export fn set_sum(m: u32) void {
    SUM_MODE = m;
}
/// Waiting tasks: owner and sum, by owner % 1024 (at most 64 tasks run at once).
var WAIT_OWNER: [1024]u32 = @splat(0);
var WAIT_SUM: [1024]u64 = @splat(0);
var MISMATCH: u32 = 0;
export fn sum_mismatch() u32 {
    return MISMATCH;
}

export fn copy_bytes() f64 {
    return @floatFromInt(@import("mem.zig").COPY_BYTES);
}
export fn copies() f64 {
    return @floatFromInt(@import("mem.zig").COPIES);
}
export fn ptr_of(id: u32) u32 {
    return PTRS[id];
}
export fn rec_buf() usize {
    return @intFromPtr(&REC);
}
export fn pages_peak() usize {
    return PEAK << 12;
}
export fn pages_used() usize {
    return if (@hasDecl(alloc, "CHUNKS_USED")) alloc.CHUNKS_USED << 12 else 0;
}
export fn sum_bytes() f64 {
    return if (@hasDecl(alloc, "SUM_BYTES")) @floatFromInt(alloc.SUM_BYTES) else 0;
}
export fn sum_acc() u32 {
    return @truncate(SUM_ACC);
}
export fn live_bytes() usize {
    return alloc.LIVE_BYTES;
}

/// The program writes its blocks: touch the first and last word.
inline fn touch(p: usize, len: usize) void {
    if (len >= 4) {
        @as(*align(1) volatile u32, @ptrFromInt(p)).* = 1;
        @as(*align(1) volatile u32, @ptrFromInt(p + len - 4)).* = 2;
    }
}

export fn run(n: u32) void {
    for (REC[0..n]) |r| {
        const op = r[0] & 0xff;
        const al = (r[0] >> 8) & 0xff;
        const off = r[0] >> 16;
        alloc.OWNER = r[1];
        if (SUM_MODE == 2 and r[1] != 0 and op != 5 and WAIT_OWNER[r[1] & 1023] == r[1]) {
            WAIT_OWNER[r[1] & 1023] = 0;
            if (alloc.sumTask(r[1]) != WAIT_SUM[r[1] & 1023]) MISMATCH += 1;
        }
        switch (op) {
            1 => {
                const p = alloc.allocOrTrap(r[3], al);
                PTRS[r[2]] = @intCast(p);
                touch(p, r[3]);
            },
            2 => alloc.hostDealloc(PTRS[r[2]] + off),
            3 => {
                const p = alloc.reallocOrTrap(PTRS[r[2]] + off, r[3], al) - off;
                PTRS[r[2]] = @intCast(p);
                touch(p + off, r[3]);
            },
            4 => _ = alloc.taskEnd(r[1]),
            5 => if (SUM_MODE != 0) {
                const v = alloc.sumTask(r[1]);
                SUM_ACC +%= v;
                if (SUM_MODE == 2) {
                    if (WAIT_OWNER[r[1] & 1023] != 0) MISMATCH +%= 1 << 16;
                    WAIT_OWNER[r[1] & 1023] = r[1];
                    WAIT_SUM[r[1] & 1023] = v;
                }
            },
            6 => alloc.adopt(PTRS[r[2]] + r[3]),
            // Tests only (not in recorded traces): a JS block, and the free after a clean trap.
            8 => if (@hasDecl(alloc, "JS_ALLOC_PUB")) {
                PTRS[r[2]] = @intCast(alloc.js_alloc(r[3]));
            } else @trap(),
            9 => _ = alloc.freeOwner(r[1]),
            else => @trap(),
        }
        if (@hasDecl(alloc, "CHUNKS_USED")) {
            if (alloc.CHUNKS_USED > PEAK) PEAK = alloc.CHUNKS_USED;
        }
    }
    alloc.OWNER = 0;
}
