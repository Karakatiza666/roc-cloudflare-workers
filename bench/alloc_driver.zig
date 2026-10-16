//! Allocator test driver (bench/alloc-test.sh): the production allocator (hostlib/alloc.zig)
//! with no app. JS writes records [op, owner, id, len] into REC and calls `run`.
//! Ops as research/alloc/replay/replay.zig: 1 alloc, 2 free, 3 realloc, 4 task end,
//! 5 sum (into SUMS[id]), 6 adopt, 8 js_alloc, 9 free after a clean trap,
//! 10 roc_alloc, 11 roc_realloc, 12 fail_next_alloc (as the host export),
//! 13 break_table(kind = id, arg = len) (PLAN.md 12d).
const lib = @import("hostlib");
const alloc = lib.alloc;

comptime {
    _ = lib.exports;
}

var PTRS: [1 << 16]u32 = undefined;
var SUMS: [256]u64 = @splat(0);
var REC: [1 << 12][4]u32 = undefined;

export fn ptr_of(id: u32) u32 {
    return PTRS[id];
}
export fn rec_buf() usize {
    return @intFromPtr(&REC);
}
export fn live_bytes() usize {
    return alloc.LIVE_BYTES;
}
/// 1 when the last trap was marked clean (`mem.TRAP_CLEAN`). `clear_trap_clean` resets it.
export fn trap_clean() u32 {
    return @intFromBool(lib.mem.TRAP_CLEAN);
}
export fn clear_trap_clean() void {
    lib.mem.TRAP_CLEAN = false;
}
/// PLAN.md 12d: the check of the allocator tables (`check_heap` without the host part). 0: pass.
export fn check_tables() u32 {
    return alloc.checkTables();
}

export fn sum_of(id: u32) u32 {
    return @truncate(SUMS[id] ^ (SUMS[id] >> 32));
}

export fn run(n: u32) void {
    for (REC[0..n]) |r| {
        const op = r[0] & 0xff;
        const al = (r[0] >> 8) & 0xff;
        const off = r[0] >> 16;
        alloc.OWNER = r[1];
        switch (op) {
            1 => PTRS[r[2]] = @intCast(alloc.allocOrTrap(r[3], al)),
            2 => alloc.hostDealloc(PTRS[r[2]] + off),
            3 => PTRS[r[2]] = @intCast(alloc.reallocOrTrap(PTRS[r[2]] + off, r[3], al) - off),
            4 => _ = alloc.taskEnd(r[1]),
            5 => SUMS[r[2]] = alloc.sumTask(r[1]),
            6 => alloc.adopt(PTRS[r[2]] + r[3]),
            8 => PTRS[r[2]] = @intCast(alloc.js_alloc(r[3])),
            9 => _ = alloc.freeOwner(r[1]),
            10 => PTRS[r[2]] = @intCast(@intFromPtr(alloc.roc_alloc(r[3], al))),
            11 => PTRS[r[2]] = @intCast(@intFromPtr(alloc.roc_realloc(@ptrFromInt(PTRS[r[2]] + off), r[3], al)) - off),
            12 => alloc.FAIL_AT = 1,
            13 => _ = alloc.breakTable(r[2], r[3]),
            else => @trap(),
        }
    }
    alloc.OWNER = 0;
}
