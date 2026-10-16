//! Bench host: one Roc request handler that waits on JS with JSPI.
//! Variant A (copy off): a fresh instance for each request, no stack copy.
//! Variant B (copy on): one instance for all requests. A wait copies the
//! used shadow stack to the heap, and back at the resume.
//! roc_platform_abi.zig: `roc glue host/ZigGlue.roc host/glue platform/main.roc` (bench/build.sh).

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const lib = @import("hostlib");

comptime {
    _ = lib.exports;
}

pub const panic = std.debug.no_panic;

const mem = lib.mem;
const gpa = lib.alloc.allocator;
const trap = mem.trap;
const RocStr = abi.RocStr;
const Bytes = abi.RocListWith(u8, false);
const AwaitRet = abi.WaitWait;
const ROC_HOST = &lib.roc.RocHostOf(abi.RocHost).host;
const StrOps = lib.roc.StrOf(RocStr);

comptime {
    mem.checkStr(RocStr);
    _ = mem.fieldOff(AwaitRet, "status", u16);
    _ = mem.fieldOff(AwaitRet, "body", Bytes);
}

inline fn slice(s: *const RocStr) []const u8 {
    const sp = mem.strAt(@intFromPtr(s));
    return @as([*]const u8, @ptrFromInt(sp.p))[0..sp.l];
}

/// 1: copy the stack at each wait (variant B). 0: no copy (variant A).
var COPY: bool = false;

export fn init(copy: u32) void {
    mem.enter();
    lib.canary.writeStackCanary();
    COPY = copy != 0;
    lib.alloc.markInit();
    // 12d: after `set_free_mark` (JS calls it before `init`) and the canary.
    CONST_SUM = constSum();
}

/// The stack pointer when wasm is idle, while a task runs. 0: no task runs.
var TASK_TOP: usize = 0;
var TASK_WAITING: u32 = 0;
var TASK_SAVED: usize = 0;
var TASK_SAVED_MAX: usize = 0;
/// The most bytes held by waiting copies at one time.
var TASK_SAVED_PEAK: usize = 0;
var TASK_WAITS: u32 = 0;

/// `owner` is the task id. `at`: the index of the record in `WAITS`. `copy`, `copy_len`: the saved
/// stack, in the task's pages. JS writes `out` during the wait. The other fields do not change
/// from `waitBegin` to the resume, so the sum covers them (PLAN.md 12a). An extern struct: the
/// field order is fixed (the map of 12-pre). `alarm`: why the resume trapped (`alarm`).
const Wait = extern struct {
    low: usize,
    top: usize,
    copy: [*]u8,
    copy_len: usize,
    out: [2]u32,
    owner: usize,
    at: usize,
    epoch: u32,
    alarm: u32,
    sum: u64,

    fn buf(w: *const Wait) []u8 {
        return w.copy[0..w.copy_len];
    }
};

/// PLAN.md 12a, 12b. 0: no sums (bench only). 1 ("afterAlarm"): a sum at each wait, a check at
/// resume only after JS set `set_suspect`. 2 ("always"): also a check at each resume after other
/// code ran (`mem.RUN_EPOCH` changed). JS sets it once, before the first task.
var SUM_MODE: u32 = 2;
var SUSPECT: bool = false;
export fn set_sum(m: u32) void {
    mem.enter();
    SUM_MODE = m;
}
/// JS sets it after an alarm: each later resume checks its sum.
export fn set_suspect(on: u32) void {
    mem.enter();
    SUSPECT = on != 0;
}
var SUM_CHECKS: u32 = 0;
/// The number of sum checks at resume.
export fn sum_checks() u32 {
    return SUM_CHECKS;
}

/// The sum of the task's memory (`sumTask`) and of the fixed fields of its `Wait` record.
fn sumWait(w: *const Wait) u64 {
    var acc = lib.alloc.sumTask(w.owner);
    for ([_]usize{ w.low, w.top, @intFromPtr(w.copy), w.copy_len, w.owner, w.at, w.epoch }) |v| acc = acc *% lib.alloc.SUM_K +% v;
    return acc;
}

/// Causes of an alarm at resume (`Wait.alarm`). `task_abort` gives them to JS as maxInt - cause.
const ALARM_SUM: u32 = 1;
const ALARM_BLOCK: u32 = 2;
/// Alarms at a resume, and unclean traps that `task_abort` saw (M11, H3).
var ALARMS: u32 = 0;
export fn alarms() u32 {
    return ALARMS;
}

/// The one alarm path of the host at a resume (PLAN.md 12b). The record stays in the table, so
/// `task_abort(id)` frees the task and gives the cause to JS. JS then runs the global check (12c).
fn alarm(w: *Wait, cause: u32) noreturn {
    w.alarm = cause;
    ALARMS += 1;
    trap();
}

/// At a resume, before the stack copy goes back. Its frames are below the idle top, where the copy goes.
fn resumeCheck(w: *Wait) void {
    if (SUSPECT or (SUM_MODE == 2 and w.epoch != mem.RUN_EPOCH)) {
        SUM_CHECKS += 1;
        if (sumWait(w) != w.sum) alarm(w, ALARM_SUM);
    }
    // The response block: JS wrote it during the wait, so the sum does not cover it.
    if (!lib.alloc.jsBlockOk(w.out[0], w.out[1])) alarm(w, ALARM_BLOCK);
}

/// Task table (PLAN.md 2c): the `Wait` record of each waiting task. JS limits the tasks in
/// flight to `task_slots()`, so it is never full.
const MAX_WAITS = 256;
var WAITS: [MAX_WAITS]?*Wait = @splat(null);
var WAITS_FREE_HINT: usize = 0;

fn waitAdd(w: *Wait) void {
    for (0..MAX_WAITS) |k| {
        const i = (WAITS_FREE_HINT + k) % MAX_WAITS;
        if (WAITS[i] == null) {
            WAITS[i] = w;
            w.at = i;
            WAITS_FREE_HINT = i + 1;
            return;
        }
    }
    trap();
}

fn waitOf(id: usize) ?*Wait {
    if (id == 0) return null;
    for (WAITS) |e| if (e) |w| if (w.owner == id) return w;
    return null;
}

/// Remove the record from the table and the counters. It does not free the record.
fn waitForget(w: *Wait) void {
    WAITS[w.at] = null;
    TASK_WAITING -= 1;
    TASK_SAVED -= w.copy_len;
}

/// A waiting task that will not resume (a cancel, or a throw at its resume point):
/// free its record and all its pages (the saved copy too). The stack is not its own: no `setSP`.
fn waitDrop(w: *Wait) usize {
    waitForget(w);
    const id = w.owner;
    lib.alloc.hostDealloc(@intFromPtr(w));
    return lib.alloc.freeOwner(id) orelse std.math.maxInt(usize);
}

inline fn getSP() usize {
    return asm volatile (
        \\.globaltype __stack_pointer, i32
        \\global.get __stack_pointer
        \\local.set %[ret]
        : [ret] "=r" (-> usize),
        :
        : .{ .memory = true });
}

inline fn setSP(v: usize) void {
    asm volatile (
        \\.globaltype __stack_pointer, i32
        \\local.get %[v]
        \\global.set __stack_pointer
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// Copy the stack of the task to the heap, give the stack to other calls.
inline fn waitBegin() *Wait {
    // 5b: the CPU signal is set. A clean trap, before the stack copy.
    lib.cpu.check();
    const top = TASK_TOP;
    if (top == 0) trap();
    const low = getSP();
    // The Wait record is a host block: JS writes `out` while the task waits. OWNER stays
    // the task, so an OOM trap here is clean (M6, PLAN.md 2c).
    const w: *Wait = @ptrFromInt(lib.alloc.allocHostOrTrap(@sizeOf(Wait), @alignOf(Wait)));
    const bp = lib.alloc.hostAlloc(top - low, 1);
    if (bp == 0) {
        lib.alloc.hostDealloc(@intFromPtr(w));
        mem.trapClean();
    }
    const buf = @as([*]u8, @ptrFromInt(bp))[0 .. top - low];
    @memcpy(buf, @as([*]const u8, @ptrFromInt(low))[0..buf.len]);
    w.* = .{ .low = low, .top = top, .copy = buf.ptr, .copy_len = buf.len, .out = .{ 0, 0 }, .owner = lib.alloc.OWNER, .at = 0, .epoch = mem.RUN_EPOCH, .alarm = 0, .sum = 0 };
    waitAdd(w);
    // 12a: after the copy, which is in the task's pages.
    if (SUM_MODE != 0) w.sum = sumWait(w);
    TASK_TOP = 0;
    lib.alloc.OWNER = 0;
    TASK_WAITING += 1;
    TASK_SAVED += buf.len;
    if (buf.len > TASK_SAVED_MAX) TASK_SAVED_MAX = buf.len;
    if (TASK_SAVED > TASK_SAVED_PEAK) TASK_SAVED_PEAK = TASK_SAVED;
    TASK_WAITS += 1;
    setSP(top);
    return w;
}

/// The stack is idle (at TOP): put the task back on it.
inline fn waitEnd(w: *Wait) [2]u32 {
    if (getSP() != w.top) trap();
    if (POKE_OUT != 0) pokeOut(w);
    if (SUM_MODE != 0) @call(.never_inline, resumeCheck, .{w});
    mem.enter();
    setSP(w.low);
    @memcpy(@as([*]u8, @ptrFromInt(w.low))[0..w.copy_len], w.buf());
    TASK_TOP = w.top;
    lib.alloc.OWNER = w.owner;
    waitForget(w);
    const out = w.out;
    lib.alloc.hostDealloc(@intFromPtr(w.copy));
    lib.alloc.hostDealloc(@intFromPtr(w));
    return out;
}

/// kind, number, text a, text b, bytes c, address of [body ptr, body len], task id. Returns the status.
extern "env" fn js_wait(kind: u32, num: f64, ap: usize, al: usize, bp: usize, bl: usize, cp: usize, cl: usize, out: usize, id: usize) u32;

/// The status that JS gives when it could not make the result block (API.md 4.1).
const STATUS_OOM: u32 = 4;

/// Status 5 (API.md 4.1, PLAN.md 3c): the task was cancelled. `task_cancel` freed its record
/// and its pages, and other tasks can use them now. So trap at once: the asm keeps the
/// compiler from moving a memory or global access before the check.
inline fn trapIfCancelled(status: u32) void {
    asm volatile (
        \\local.get %[s]
        \\i32.const 5
        \\i32.eq
        \\if
        \\unreachable
        \\end_if
        :
        : [s] "r" (status),
        : .{ .memory = true });
}

/// Test export (PLAN.md 4-pre, 4a, 5c): the next `roc_wait` traps at its start, at the normal stack depth
/// of the task. 1: an out-of-bounds write. 2: `unreachable`. Both are unclean (V2).
/// 3: `unreachable` with a wrapped stack pointer, as a task that a kill left on a stale stack (5c).
/// 4: a wild write (PLAN.md 12a, `bench/wild.mjs`): `set_wild` random words between the host
/// global `WILD_BASE` and the end of memory, then `unreachable` (as the research hook).
/// 5: the same wild write, then the task waits, and traps (unclean) after its resume. Other
/// tasks resume onto the damage before the alarm.
var FAULT_NEXT: u32 = 0;
export fn fault_next_wait(kind: u32) void {
    mem.enter();
    FAULT_NEXT = kind;
}
var WILD_BASE: u32 = 0;
var WILD_TRAP: usize = 0;
var WILD_SEED: u32 = 1;
var WILD_WORDS: u32 = 16;
export fn set_wild(seed: u32, words: u32) void {
    mem.enter();
    WILD_SEED = seed;
    WILD_WORDS = words;
}
fn wildWrite() void {
    const top = @wasmMemorySize(0) * 65536;
    const base = @intFromPtr(&WILD_BASE);
    for (0..WILD_WORDS) |_| {
        WILD_SEED = WILD_SEED *% 1103515245 +% 12345;
        mem.wr32(base + (WILD_SEED % (top - base - 8)) & ~@as(usize, 3), WILD_SEED);
    }
}

/// Test export (PLAN.md 12a, 12b): a wild write, with no trap, into the memory of waiting task `id`.
/// 1: `Wait.low` += arg. 2: XOR arg into the first data word of the first JS block that `id` adopted.
/// 3: at the next resume of `id`, `out[1]` (the length of the response block) += arg, before the
/// checks: JS writes `out` just before the resume. 4: XOR arg into the word at the address `id`
/// (any memory). Returns the address, or 0 when there is none.
var POKE_OUT: usize = 0;
var POKE_OUT_ADD: u32 = 0;
export fn poke_wait(id: usize, kind: u32, arg: u32) usize {
    mem.enter();
    if (kind == 4) {
        mem.wr32(id, mem.rd32(id) ^ arg);
        return id;
    }
    const w = waitOf(id) orelse return 0;
    switch (kind) {
        1 => {
            w.low +%= arg;
            return @intFromPtr(&w.low);
        },
        2 => {
            const b = lib.alloc.adoptedBlock(id);
            if (b == 0) return 0;
            mem.wr32(b + 8, mem.rd32(b + 8) ^ arg);
            return b + 8;
        },
        3 => {
            POKE_OUT = id;
            POKE_OUT_ADD = arg;
            return @intFromPtr(&w.out[1]);
        },
        else => return 0,
    }
}
fn pokeOut(w: *Wait) void {
    if (w.owner != POKE_OUT) return;
    POKE_OUT = 0;
    w.out[1] +%= POKE_OUT_ADD;
}

export fn roc_wait(kind: u32, num: u64, a: RocStr, b: RocStr, c: Bytes) callconv(.c) AwaitRet {
    if (FAULT_NEXT != 0) {
        const k = FAULT_NEXT;
        FAULT_NEXT = 0;
        if (k == 1) @as(*volatile u32, @ptrFromInt(0xFFFF_FFF0)).* = 1;
        if (k == 3) setSP(0xFFFF_FFF0);
        if (k == 4 or k == 5) wildWrite();
        if (k == 5) WILD_TRAP = lib.alloc.OWNER else @trap();
    }
    const as = slice(&a);
    const bs = slice(&b);
    const cs = c.items();
    const id = lib.alloc.OWNER;
    var out: [2]u32 = .{ 0, 0 };
    var status: u32 = 0;
    if (COPY) {
        const w = waitBegin();
        status = js_wait(kind, @floatFromInt(num), @intFromPtr(as.ptr), as.len, @intFromPtr(bs.ptr), bs.len, @intFromPtr(cs.ptr), cs.len, @intFromPtr(&w.out), id);
        trapIfCancelled(status);
        out = waitEnd(w);
        if (WILD_TRAP != 0 and WILD_TRAP == id) {
            WILD_TRAP = 0;
            @trap();
        }
    } else {
        status = js_wait(kind, @floatFromInt(num), @intFromPtr(as.ptr), as.len, @intFromPtr(bs.ptr), bs.len, @intFromPtr(cs.ptr), cs.len, @intFromPtr(&out), id);
        trapIfCancelled(status);
    }
    // Status 4: `js_alloc` was out of memory. A clean OOM trap for this task (PLAN.md 2a).
    // The task is back on its stack and has its owner, so `task_abort` frees its pages.
    if (status == STATUS_OOM) mem.trapClean();
    a.decref(ROC_HOST);
    b.decref(ROC_HOST);
    c.decref(ROC_HOST);
    return .{ .status = @truncate(status), .body = bytesFrom(out[0], out[1]) };
}

/// A List(U8) over the js_alloc block at `ptr`, which it takes.
fn bytesFrom(ptr: usize, len: usize) Bytes {
    if (len == 0) {
        if (ptr != 0) lib.alloc.hostDealloc(ptr - 4);
        return .{ .elements_ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    }
    lib.alloc.adopt(ptr);
    return .{ .elements_ptr = @ptrFromInt(ptr), .length = len, .capacity_or_alloc_ptr = len << 1 };
}

/// Run the handler on the request in the js_alloc block at `p` (taken), as task `id`.
/// Returns a heap block [len u32][bytes] for JS; JS frees it with `res_free`.
/// No frame of its own: TOP is the stack pointer of the JS call.
export fn handle(p: usize, l: usize, id: usize) usize {
    // JS gives the id (PLAN.md 2c) and never reuses one: 0 is the host, maxInt the JS slot.
    if (id == 0 or id == std.math.maxInt(usize)) trap();
    mem.enter();
    lib.alloc.OWNER = id;
    // A flag left by an earlier trap that nobody aborted must not make this task's trap clean.
    mem.TRAP_CLEAN = false;
    lib.cpu.clearCause();
    lib.alloc.adopt(p);
    TASK_TOP = getSP();
    const r = @call(.never_inline, handleImpl, .{ p, l });
    TASK_TOP = 0;
    // The task ended: its pages go back to the pool.
    _ = lib.alloc.taskEnd(lib.alloc.OWNER);
    lib.alloc.OWNER = 0;
    return r;
}

fn handleImpl(p: usize, l: usize) usize {
    const res = abi.roc_handle(StrOps.fromParts(p, l));
    const s = slice(&res);
    // The response outlives the task: it is a host block (owner 0).
    const blk = lib.alloc.allocHostOrTrap(4 + s.len, 4);
    mem.wrUsize(blk, s.len);
    mem.copyBytes(blk + 4, @intFromPtr(s.ptr), s.len);
    res.decref(ROC_HOST);
    return blk;
}

export fn res_free(p: usize) void {
    mem.enter();
    lib.alloc.hostDealloc(p);
}

/// After a trap in task `id`: free its pages and its task slot. Returns the bytes freed, or maxInt
/// when the trap was not clean (`mem.TRAP_CLEAN`, or a stack overflow of a stack-first build,
/// 4-pre): an alarm, JS runs the global check (12c). maxInt - cause: an alarm at the resume of
/// `id` (12b: 1 its sum differs, 2 its response block is bad).
/// `rangeError`: 1 when JS got a V8 stack RangeError.
/// A waiting task (a throw at its resume point skipped `waitEnd`, PLAN.md 2c): free its
/// record and pages, as `task_cancel`. A task that ran: give the stack back first, so the
/// calls below have a sound stack (V1: an overflow wraps the stack pointer).
/// No frame of its own: a frame epilogue would write the old stack pointer back.
export fn task_abort(id: usize, rangeError: u32) usize {
    // Read the stack pointer first: the trap left it where it was (V1).
    const sp = getSP();
    mem.enter();
    if (TASK_TOP != 0) {
        // 4-pre: a stack-first overflow wrote nothing but the stack, so the trap is clean.
        // It shows as a wrapped stack pointer, or as a V8 RangeError (JS says so, the stack
        // pointer is then not wrapped: V1).
        const overflow = lib.canary.overflowed(sp, TASK_TOP) or (rangeError != 0 and lib.canary.STACK_FIRST);
        if (lib.alloc.OWNER != 0 and overflow) mem.TRAP_CLEAN = true;
        setSP(TASK_TOP);
    }
    TASK_TOP = 0;
    const freed = @call(.never_inline, abortFree, .{id});
    @call(.never_inline, lib.canary.repair, .{});
    return freed;
}

fn abortFree(id: usize) usize {
    if (waitOf(id)) |w| {
        const cause = w.alarm;
        const freed = waitDrop(w);
        return if (cause != 0) std.math.maxInt(usize) - cause else freed;
    }
    // The task that ran is OWNER (a trap in a host call from JS has OWNER 0).
    const clean = mem.TRAP_CLEAN;
    mem.TRAP_CLEAN = false;
    const who = if (lib.alloc.OWNER != 0) lib.alloc.OWNER else id;
    lib.alloc.OWNER = 0;
    // 12c: an unclean trap frees the task too. The instance stays when the global check passes,
    // so its pages and its task slot must go back.
    const freed = lib.alloc.freeOwner(who);
    if (clean) return freed orelse std.math.maxInt(usize);
    ALARMS += 1;
    return std.math.maxInt(usize);
}

/// Cancel waiting task `id` (PLAN.md 3c): free its record and its pages. JS then answers
/// its wait with status 5, and the task traps before it touches memory. Returns the bytes
/// freed, or maxInt when `id` does not wait.
export fn task_cancel(id: usize) usize {
    mem.enter();
    const w = waitOf(id) orelse return std.math.maxInt(usize);
    return waitDrop(w);
}

// ---------------------------------------------------------------- global check (PLAN.md 12d)

/// Codes of `check_heap` after those of `lib.alloc.checkTables` (1 to 11).
const CHECK_CONST: u32 = 12;
const CHECK_HOST: u32 = 13;
const CHECK_WAITS: u32 = 14;
const CHECK_LOG: u32 = 15;

/// Linker symbols: the start of the data (`.rodata` first), the top of the stack.
extern const __global_base: u8;
extern const __stack_high: u8;

/// The sum of the constant data at `init`.
var CONST_SUM: u64 = 0;

/// The end of `.rodata`: the lowest host global with a start value (they are the first data of
/// `.data`, which follows `.rodata`). All bytes below it, from `__global_base`, are constant.
fn rodataEnd() usize {
    const firsts = [_]usize{ @intFromPtr(&SUM_MODE), @intFromPtr(&WILD_SEED), @intFromPtr(&WILD_WORDS), @intFromPtr(ROC_HOST), lib.alloc.firstData(), lib.cpu.firstData() };
    return std.mem.min(usize, &firsts);
}

/// Constant data (PLAN.md 12-pre): the `.rodata` of the host and of Roc, the free mark, the host
/// tables, the canary globals and the canary.
fn constSum() u64 {
    const lo = @intFromPtr(&__global_base);
    var acc = mem.sumBytes(lo, rodataEnd() - lo, 1);
    acc = mem.sumBytes(@intFromPtr(ROC_HOST), @sizeOf(abi.RocHost), acc);
    acc = lib.alloc.sumConst(acc);
    return lib.canary.sumConst(acc);
}

inline fn byteOf(p: anytype) u8 {
    return @as(*const u8, @ptrCast(p)).*;
}

/// Host globals in range. No task is in wasm when JS calls the check.
fn checkHost() u32 {
    if (TASK_TOP != 0 or lib.alloc.OWNER != 0) return CHECK_HOST;
    if (byteOf(&COPY) > 1 or byteOf(&SUSPECT) > 1 or byteOf(&mem.TRAP_CLEAN) > 1) return CHECK_HOST;
    if (SUM_MODE > 2 or FAULT_NEXT > 5 or FILLED > FILL.len or !lib.cpu.causeOk()) return CHECK_HOST;
    return 0;
}

/// `WAITS` (PLAN.md 12-pre decisions): each entry is null or a `Wait` record in a host block, `at` is its index, the copy is
/// a block of its task, one record per task. `TASK_WAITING` and `TASK_SAVED` match. No task runs,
/// so each task slot in use belongs to a waiting task.
fn checkWaits() u32 {
    if (WAITS_FREE_HINT > MAX_WAITS) return CHECK_WAITS;
    var slots: [4]u64 = @splat(0);
    var n: usize = 0;
    var saved: usize = 0;
    for (WAITS, 0..) |e, i| {
        const w = e orelse continue;
        if (!lib.alloc.hostBlockOk(@intFromPtr(w), @sizeOf(Wait))) return CHECK_WAITS;
        if (w.at != i or w.low >= w.top or w.top > @intFromPtr(&__stack_high) or w.low < lib.canary.STACK_LIMIT) return CHECK_WAITS;
        if (w.copy_len != w.top - w.low or w.alarm > ALARM_BLOCK) return CHECK_WAITS;
        const s = lib.alloc.slotOf(w.owner) orelse return CHECK_WAITS;
        if (!lib.alloc.slotBlockOk(@intFromPtr(w.copy), s, w.copy_len)) return CHECK_WAITS;
        const bit = @as(u64, 1) << @intCast(s & 63);
        if (slots[s >> 6] & bit != 0) return CHECK_WAITS;
        slots[s >> 6] |= bit;
        n += 1;
        saved += w.copy_len;
    }
    if (n != TASK_WAITING or saved != TASK_SAVED) return CHECK_WAITS;
    if (COPY and lib.alloc.slotsInUse() != n) return CHECK_WAITS;
    return 0;
}

/// PLAN.md 12d: the global check of the shared memory (allocator tables, host globals, `WAITS`,
/// the log, constant data). JS calls it when no task is in wasm: after an alarm (12c), when the
/// instance is idle, and every `heapCheckEvery` requests (12e). 0: pass. Else the code of the
/// first check that failed: JS replaces the instance (M1).
export fn check_heap() u32 {
    mem.enter();
    const h = checkHost();
    if (h != 0) return h;
    const t = lib.alloc.checkTables();
    if (t != 0) return t;
    const w = checkWaits();
    if (w != 0) return w;
    if (!lib.roc.logOk()) return CHECK_LOG;
    if (constSum() != CONST_SUM) return CHECK_CONST;
    return 0;
}

/// Test export (PLAN.md 12d, 12e): a wild write into one entry of the shared memory, with no
/// trap. Kinds 1 to 16: allocator tables (`lib.alloc.breakTable`). 20: a byte of `.rodata` at
/// `__global_base` + arg. 21: a word of the canary. 22: `TASK_WAITING`. 23: `at` of the first
/// `Wait` record. 24: its copy length. 25: the log length (+1). 26: `TASK_TOP`. 27: `SUM_MODE`.
/// Returns 1 when it found a target, else 0.
export fn break_table(kind: u32, arg: usize) u32 {
    mem.enter();
    if (kind < 20) return lib.alloc.breakTable(kind, arg);
    var first: ?*Wait = null;
    for (WAITS) |e| if (e) |w| {
        first = w;
        break;
    };
    switch (kind) {
        20 => mem.wr8(@intFromPtr(&__global_base) + arg, mem.rd8(@intFromPtr(&__global_base) + arg) ^ 1),
        21 => mem.wr32(lib.canary.CANARY_BASE + 4 * (arg & 1023), mem.rd32(lib.canary.CANARY_BASE + 4 * (arg & 1023)) ^ 1),
        22 => TASK_WAITING += 1,
        23 => (first orelse return 0).at += 1,
        24 => (first orelse return 0).copy_len += 4,
        25 => lib.roc.LOG.len += 1,
        26 => TASK_TOP = 16,
        27 => SUM_MODE = 7,
        else => return 0,
    }
    return 1;
}

/// The most tasks in flight at once. JS refuses a new task above it (PLAN.md 2c).
export fn task_slots() u32 {
    return lib.alloc.TASK_SLOTS;
}

/// Overhead bench: `n` rounds of `k` allocations of `size` bytes, then their frees.
export fn alloc_bench(n: u32, k: u32, size: usize) u32 {
    mem.enter();
    var ptrs: [256]usize = undefined;
    var sum: u32 = 0;
    for (0..n) |_| {
        for (0..k) |i| ptrs[i] = lib.alloc.allocOrTrap(size, 8);
        for (0..k) |i| {
            sum +%= @truncate(ptrs[i]);
            lib.alloc.hostDealloc(ptrs[i]);
        }
    }
    return sum;
}

/// Walk bench: keep `count` live spans of `size` bytes under owner `tag` (0: free them).
var FILL: [65536]usize = undefined;
var FILLED: usize = 0;
var FILL_TAG: usize = 0;
export fn heap_fill(count: usize, size: usize, tag: usize) void {
    mem.enter();
    const saved = lib.alloc.OWNER;
    // A free must come from the owner (the owner check at free).
    lib.alloc.OWNER = FILL_TAG;
    for (0..FILLED) |i| lib.alloc.hostDealloc(FILL[i]);
    FILLED = 0;
    FILL_TAG = tag;
    lib.alloc.OWNER = tag;
    for (0..@min(count, FILL.len)) |i| {
        FILL[i] = lib.alloc.allocOrTrap(size, 8);
        FILLED += 1;
    }
    lib.alloc.OWNER = saved;
}
/// One heap walk for an owner that has no spans. Returns the bytes freed (0), or maxInt.
export fn walk_bench(owner: usize) usize {
    mem.enter();
    return lib.alloc.freeOwner(owner) orelse std.math.maxInt(usize);
}

export fn task_waiting() u32 {
    return TASK_WAITING;
}
export fn task_saved() usize {
    return TASK_SAVED;
}
export fn task_saved_max() usize {
    return TASK_SAVED_MAX;
}
export fn task_saved_peak() usize {
    return TASK_SAVED_PEAK;
}
export fn task_waits() u32 {
    return TASK_WAITS;
}
/// Zero the copy counters, before a measured run.
export fn stats_reset() void {
    mem.enter();
    TASK_SAVED_MAX = 0;
    TASK_SAVED_PEAK = 0;
    TASK_WAITS = 0;
}
/// The copy work of `iters` waits of `len` bytes alone: alloc, copy out, copy back, free.
/// It copies the bytes at [4096, 4096 + len), inside the stack area.
export fn copy_bench(len: usize, iters: u32) u32 {
    mem.enter();
    var sum: u32 = 0;
    const src: [*]u8 = @ptrFromInt(4096);
    for (0..iters) |_| {
        const w = gpa.create(Wait) catch trap();
        const buf = gpa.alloc(u8, len) catch trap();
        @memcpy(buf, src[0..len]);
        w.* = .{ .low = 4096, .top = 4096 + len, .copy = buf.ptr, .copy_len = len, .out = .{ 0, 0 }, .owner = 0, .at = 0, .epoch = 0, .alarm = 0, .sum = 0 };
        std.mem.doNotOptimizeAway(w);
        @memcpy(src[0..len], w.buf());
        sum +%= buf[len / 2];
        gpa.free(w.buf());
        gpa.destroy(w);
    }
    return sum;
}

/// Turn the stack copy on or off. Off is safe only with one request at a time.
export fn set_copy(on: u32) void {
    mem.enter();
    COPY = on != 0;
}
/// Test export (PLAN.md 6d, 2a): the next allocation gives 0, from `roc_alloc` or `js_alloc`.
export fn fail_next_alloc() void {
    mem.enter();
    lib.alloc.FAIL_AT = 1;
}
/// Test export (PLAN.md 2c): allocation number `n` from now gives 0 (1: the next one).
export fn fail_alloc_at(n: u32) void {
    mem.enter();
    lib.alloc.FAIL_AT = n;
}
export fn live_bytes() usize {
    return lib.alloc.LIVE_BYTES;
}
