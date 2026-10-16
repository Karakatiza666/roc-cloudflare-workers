//! Host: one Roc request handler that waits on JS with JSPI. Production by default, bench with `zig build -Dbench=true` (PLAN.md 7a).
//! Variant A (copy off): a fresh instance for each request, no stack copy.
//! Variant B (copy on): one instance for all requests. A wait copies the
//! used shadow stack to the heap, and back at the resume.
//! roc_platform_abi.zig: `roc glue host/ZigGlue.roc host/glue platform/main.roc` (bench/build.sh).

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const lib = @import("hostlib");

/// PLAN.md 7a: the bench host has the test exports and their hooks. In the production host each
/// use of a hook is behind `if (BENCH)`, so the compiler leaves it out.
const BENCH = lib.BENCH;

comptime {
    _ = lib.exports;
}

pub const panic = std.debug.no_panic;

const mem = lib.mem;
const gpa = lib.alloc.allocator;
const trap = mem.trap;
const RocStr = abi.RocStr;
const Bytes = abi.RocListWith(u8, false);
const ROC_HOST = &lib.roc.RocHostOf(abi.RocHost).host;
const StrOps = lib.roc.StrOf(RocStr);
/// The CBOR profile of API.md 5 over the glue types (HD1: its `comptime` checks).
const cbor = @import("cbor.zig").Codec(abi);
const JsVal = abi.Js;
const BridgeRet = abi.HostAwait;

comptime {
    mem.checkStr(RocStr);
    _ = mem.fieldOff(BridgeRet, "status", u8);
    _ = mem.fieldOff(BridgeRet, "value", JsVal);
    _ = mem.fieldOff(abi.HostCall, "value", JsVal);
    _ = mem.fieldOff(abi.HostNative, "bytes", Bytes);
    _ = mem.fieldOff(abi.HostNative, "status", u8);
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
/// Returns 1 when the mode is set. 0: refused, the mode stays. The production host refuses mode 0
/// (PLAN.md 7a, 12b: no sums is for benches only).
export fn set_sum(m: u32) u32 {
    mem.enter();
    if (!BENCH and m == 0) return 0;
    SUM_MODE = m;
    return 1;
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
/// Not an alarm yet: the host code of the wait or of the resume runs (the sum, the checks, the
/// copy). A trap there leaves this mark, and `task_abort` counts it as an unclean trap (12c). A
/// throw into the task at its resume point (2c) runs no host code and leaves 0: clean.
const IN_HOST: u32 = 3;
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
        lib.cpu.oom();
    }
    const buf = @as([*]u8, @ptrFromInt(bp))[0 .. top - low];
    @memcpy(buf, @as([*]const u8, @ptrFromInt(low))[0..buf.len]);
    w.* = .{ .low = low, .top = top, .copy = buf.ptr, .copy_len = buf.len, .out = .{ 0, 0 }, .owner = lib.alloc.OWNER, .at = 0, .epoch = mem.RUN_EPOCH, .alarm = IN_HOST, .sum = 0 };
    waitAdd(w);
    // 12a: after the copy, which is in the task's pages.
    if (SUM_MODE != 0) w.sum = sumWait(w);
    w.alarm = 0;
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
    w.alarm = IN_HOST;
    if (getSP() != w.top) trap();
    if (BENCH and POKE_OUT != 0) pokeOut(w);
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

/// Test export (PLAN.md 4-pre, 4a, 5c): the next wait (`roc_await`) traps at its start, at the normal stack depth
/// of the task. 1: an out-of-bounds write. 2: `unreachable`. Both are unclean (V2).
/// 3: `unreachable` with a wrapped stack pointer, as a task that a kill left on a stale stack (5c).
/// 4: a wild write (PLAN.md 12a, `bench/wild.mjs`): `set_wild` random words between the host
/// global `WILD_BASE` and the end of memory, then `unreachable` (as the research hook).
/// 5: the same wild write, then the task waits, and traps (unclean) after its resume. Other
/// tasks resume onto the damage before the alarm.
var FAULT_NEXT: u32 = 0;
fn fault_next_wait(kind: u32) callconv(.c) void {
    mem.enter();
    FAULT_NEXT = kind;
}
var WILD_BASE: u32 = 0;
var WILD_TRAP: usize = 0;
var WILD_SEED: u32 = 1;
var WILD_WORDS: u32 = 16;
fn set_wild(seed: u32, words: u32) callconv(.c) void {
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
fn poke_wait(id: usize, kind: u32, arg: u32) callconv(.c) usize {
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

/// The test hooks of `fault_next_wait`, at the start of a wait.
inline fn waitHooks() void {
    if (BENCH and FAULT_NEXT != 0) {
        const k = FAULT_NEXT;
        FAULT_NEXT = 0;
        if (k == 1) @as(*volatile u32, @ptrFromInt(0xFFFF_FFF0)).* = 1;
        if (k == 3) setSP(0xFFFF_FFF0);
        if (k == 4 or k == 5) wildWrite();
        if (k == 5) WILD_TRAP = lib.alloc.OWNER else @trap();
    }
}

// ---------------------------------------------------------------- the bridge (API.md 4, 4.1)

/// `(task_id, arg_ptr, arg_len, out_ptr) -> status` (API.md 4.1). `js_await` is wrapped in
/// `WebAssembly.Suspending`. JS reads the argument before its first await, and writes
/// `[ptr, len]` of a `js_alloc` block with the CBOR of the result at `out_ptr`.
extern "env" fn js_await(id: usize, ap: usize, al: usize, out: usize) u32;
extern "env" fn js_call(id: usize, ap: usize, al: usize, out: usize) u32;

/// Status 3 (API.md 4): a bad program. Also a result block that is not one value of the profile.
const STATUS_BAD: u8 = 3;

/// The program as CBOR in a block of the task: `freeOwner` frees it after a trap or a cancel of the
/// task, as the saved stack. Null: deeper than 64 containers (J3).
fn encodeArg(prog: *const JsVal) ?mem.Span {
    const n = cbor.encodedSize(prog) orelse return null;
    const p = lib.alloc.allocOrTrap(@max(n, 1), 1);
    cbor.encode(prog, @as([*]u8, @ptrFromInt(p))[0..n]);
    return .{ .p = p, .l = n };
}

/// The result block of JS to a `Js` value of the task (RS4), then the block is freed. The block is
/// adopted first, so a trap in the decode (out of memory) frees it with the task.
fn resultOf(status: u32, out: [2]u32) BridgeRet {
    const p: usize = out[0];
    const l: usize = out[1];
    // A block that is not a JS block (damage): an unclean trap. A resume checked it already (12b).
    if (!lib.alloc.jsBlockOk(p, l)) trap();
    const bytes: []const u8 = if (p == 0) &.{} else @as([*]const u8, @ptrFromInt(p))[0..l];
    lib.alloc.adopt(p);
    const d = cbor.decode(bytes, ROC_HOST);
    lib.alloc.hostDealloc(p);
    switch (d) {
        .value => |v| return .{ .value = v, .status = if (status <= STATUS_BAD) @intCast(status) else STATUS_BAD },
        .problem => |pr| {
            var buf: [96]u8 = undefined;
            return .{ .value = cbor.errorValue("BadResult", cbor.problemText(pr, &buf), ROC_HOST), .status = STATUS_BAD };
        },
    }
}

/// One crossing: encode the program, give it to JS, decode the result. `waits`: `js_await`, with
/// the stack copy of variant B. The hosted function owns `prog` (glue `decref`).
inline fn bridge(prog: JsVal, comptime waits: bool) BridgeRet {
    if (waits) waitHooks();
    const id = lib.alloc.OWNER;
    const arg = encodeArg(&prog);
    prog.decref(ROC_HOST);
    // J3: a program deeper than 64 containers never reaches JS (status 1, the RangeError of the shim).
    const a = arg orelse return .{ .value = cbor.errorValue("RangeError", "CBOR: value is deeper than 64 levels, or has a cycle", ROC_HOST), .status = 1 };
    var out: [2]u32 = .{ 0, 0 };
    var status: u32 = 0;
    if (waits and COPY) {
        const w = waitBegin();
        status = js_await(id, a.p, a.l, @intFromPtr(&w.out));
        trapIfCancelled(status);
        out = waitEnd(w);
        if (BENCH and WILD_TRAP != 0 and WILD_TRAP == id) {
            WILD_TRAP = 0;
            @trap();
        }
    } else {
        status = if (waits) js_await(id, a.p, a.l, @intFromPtr(&out)) else js_call(id, a.p, a.l, @intFromPtr(&out));
        trapIfCancelled(status);
    }
    lib.alloc.hostDealloc(a.p);
    // Status 4: `js_alloc` was out of memory. A clean OOM trap for this task (PLAN.md 2a).
    // The task is back on its stack and has its owner, so `task_abort` frees its pages.
    if (status == STATUS_OOM) lib.cpu.oom();
    return resultOf(status, out);
}

export fn roc_await(prog: JsVal) callconv(.c) BridgeRet {
    return bridge(prog, true);
}

export fn roc_call(prog: JsVal) callconv(.c) BridgeRet {
    return bridge(prog, false);
}

/// API.md 8, PLAN.md 8e: one Native op. The owner is the task that runs (a handle of another task is status 1).
/// Status 4 (no memory) is a clean OOM trap, as a failed `roc_alloc`. The result is a new list of the task.
export fn roc_native(op: u32, bytes: Bytes) callconv(.c) abi.HostNative {
    // The stack that the op needs is free, or this is a clean trap (the canary stays whole).
    lib.canary.reserve(lib.native.stackNeed(op));
    const r = lib.native.call(gpa, lib.alloc.OWNER, op, bytes.items());
    defer r.release(gpa);
    // After the call: the input points into the list.
    bytes.decref(ROC_HOST);
    if (r.status == 4) lib.cpu.oom();
    return .{ .bytes = Bytes.fromSlice(r.bytes, ROC_HOST), .status = r.status };
}

/// Test export (API.md 5.1, HD5, HD6): decode the `len` bytes at `p`, then drop the value. 0: a value,
/// else the fault (`cbor.Fault`). The values are host blocks (no task runs): live bytes show a leak.
fn cbor_check(p: usize, len: usize) callconv(.c) u32 {
    mem.enter();
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrFromInt(p))[0..len];
    switch (cbor.decode(bytes, ROC_HOST)) {
        .value => |v| {
            v.decref(ROC_HOST);
            return 0;
        },
        .problem => |pr| return @intFromEnum(pr.fault),
    }
}

/// Test export (API.md 11, "same bytes in Zig and JS"): decode, then encode again into a host block
/// `[len u32][bytes]` that JS frees with `res_free`. 0: the bytes are not a value.
fn cbor_echo(p: usize, len: usize) callconv(.c) usize {
    mem.enter();
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrFromInt(p))[0..len];
    switch (cbor.decode(bytes, ROC_HOST)) {
        .value => |v| {
            defer v.decref(ROC_HOST);
            const n = cbor.encodedSize(&v) orelse return 0;
            const blk = lib.alloc.allocHostOrTrap(4 + n, 4);
            mem.wrUsize(blk, n);
            cbor.encode(&v, @as([*]u8, @ptrFromInt(blk + 4))[0..n]);
            return blk;
        },
        .problem => return 0,
    }
}

/// Run the event in the js_alloc block at `p` (taken, the CBOR of a `Js` value, API.md 4.1), as task `id`.
/// Returns a heap block [len u32][CBOR of the outcome] for JS; JS frees it with `res_free`.
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
    // The task ended: its pages go back to the pool. What is left is a leak (H3, `leaked_at_end`).
    _ = lib.alloc.taskDone(lib.alloc.OWNER);
    lib.alloc.OWNER = 0;
    return r;
}

/// Test export (PLAN.md 4h): the next task keeps a block of `n` bytes to its end, a leak
/// (`leaked_at_end`).
var LEAK_NEXT: usize = 0;
fn leak_next(n: usize) callconv(.c) void {
    mem.enter();
    LEAK_NEXT = n;
}

fn handleImpl(p: usize, l: usize) usize {
    const bytes: []const u8 = if (p == 0) &.{} else @as([*]const u8, @ptrFromInt(p))[0..l];
    var buf: [96]u8 = undefined;
    // The event is a value of the task. A block that is not one value is a shim bug: a clean trap with a log line.
    const ev = switch (cbor.decode(bytes, ROC_HOST)) {
        .value => |v| v,
        .problem => |pr| badEvent("the event is not a Js value: ", cbor.problemText(pr, &buf)),
    };
    // The event block stays until the task ends, as the request block did before 8b: a JS block that the task
    // adopted, in the sums of its waits (12a). A trap frees it with the task (`freeAdopted`).
    const res = abi.roc_event(ev);
    lib.alloc.hostDealloc(p);
    if (BENCH and LEAK_NEXT != 0) {
        _ = lib.alloc.allocOrTrap(LEAK_NEXT, 8);
        LEAK_NEXT = 0;
    }
    // The outcome outlives the task: it is a host block (owner 0).
    const n = cbor.encodedSize(&res) orelse badEvent("the outcome is deeper than 64 levels", "");
    const blk = lib.alloc.allocHostOrTrap(4 + n, 4);
    mem.wrUsize(blk, n);
    cbor.encode(&res, @as([*]u8, @ptrFromInt(blk + 4))[0..n]);
    res.decref(ROC_HOST);
    return blk;
}

/// One log line (6a, owner 0), as the text of a crash, then a clean trap of the task.
fn badEvent(what: []const u8, detail: []const u8) noreturn {
    var line: [160]u8 = undefined;
    const a = @min(what.len, line.len);
    @memcpy(line[0..a], what[0..a]);
    const b = @min(detail.len, line.len - a);
    @memcpy(line[a..][0..b], detail[0..b]);
    lib.roc.logPushCopy(@intFromPtr(&line), a + b, lib.roc.LOG_LEVEL_LOG);
    mem.trapClean();
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
        // A trap in the host code of the wait or the resume: unclean (12c).
        if (cause == IN_HOST) {
            ALARMS += 1;
            return std.math.maxInt(usize);
        }
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
/// A task trapped and JS has not called `task_abort` yet (`TASK_TOP` or `OWNER` is set, or a
/// `Wait` record has the mark `IN_HOST`). Not a failure when JS calls the check from a promise
/// job: the catch of that task can still be in the queue. At a timer (no job in the queue) it is.
const CHECK_BUSY: u32 = 16;

/// Linker symbols: the start of the data (`.rodata` first), the top of the stack.
extern const __global_base: u8;
extern const __stack_high: u8;

/// The sum of the constant data at `init`.
var CONST_SUM: u64 = 0;

/// The end of `.rodata`: the lowest host global with a start value (they are the first data of
/// `.data`, which follows `.rodata`). All bytes below it, from `__global_base`, are constant.
fn rodataEnd() usize {
    const firsts = [_]usize{ @intFromPtr(&SUM_MODE), @intFromPtr(ROC_HOST), lib.alloc.firstData(), lib.cpu.firstData() };
    const first = std.mem.min(usize, &firsts);
    return if (BENCH) @min(first, @intFromPtr(&WILD_SEED), @intFromPtr(&WILD_WORDS)) else first;
}

/// Constant data (PLAN.md 12-pre): the `.rodata` of the host and of Roc, the free mark, the host
/// tables (the Roc host table and its context byte, the allocator and its vtable), the canary
/// globals and the canary. `research/memmap/memmap.mjs` checks that a flip of each byte of the
/// constant ranges of its map makes this sum differ.
fn constSum() u64 {
    const lo = @intFromPtr(&__global_base);
    var acc = mem.sumBytes(lo, rodataEnd() - lo, 1);
    acc = mem.sumBytes(@intFromPtr(ROC_HOST), @sizeOf(abi.RocHost), acc);
    acc = mem.sumBytes(@intFromPtr(&lib.roc.RocHostOf(abi.RocHost).env), 1, acc);
    acc = lib.alloc.sumConst(acc);
    return lib.canary.sumConst(acc);
}

inline fn byteOf(p: anytype) u8 {
    return @as(*const u8, @ptrCast(p)).*;
}

/// Host globals in range. No task is in wasm when JS calls the check.
fn checkHost() u32 {
    if (byteOf(&COPY) > 1 or byteOf(&SUSPECT) > 1 or byteOf(&mem.TRAP_CLEAN) > 1) return CHECK_HOST;
    if (SUM_MODE > 2 or !lib.cpu.causeOk()) return CHECK_HOST;
    if (BENCH and (FAULT_NEXT > 5 or FILLED > FILL.len)) return CHECK_HOST;
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
/// instance is idle, and every `heapCheckEvery` requests (12e). 0: pass. `CHECK_BUSY`: a trapped
/// task is not aborted yet. Else the code of the first check that failed: JS replaces the instance (M1).
export fn check_heap() u32 {
    mem.enter();
    if (TASK_TOP != 0 or lib.alloc.OWNER != 0) return CHECK_BUSY;
    for (WAITS) |e| if (e) |w| if (w.alarm == IN_HOST) return CHECK_BUSY;
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
/// trap. Kinds 1 to 19: allocator tables (19: the live count is 0, 4j) (`lib.alloc.breakTable`). 20: a byte of `.rodata` at
/// `__global_base` + arg. 21: a word of the canary. 22: `TASK_WAITING`. 23: `at` of the first
/// `Wait` record. 24: its copy length. 25: the log length (+1). 26: `TASK_TOP`. 27: `SUM_MODE`.
/// 28: the log length = arg (JS then reads past the memory end in `drainLog`, 12c).
/// Returns 1 when it found a target, else 0.
fn break_table(kind: u32, arg: usize) callconv(.c) u32 {
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
        28 => lib.roc.LOG.len = arg,
        else => return 0,
    }
    return 1;
}

/// The most tasks in flight at once. JS refuses a new task above it (PLAN.md 2c).
export fn task_slots() u32 {
    return lib.alloc.TASK_SLOTS;
}

/// Overhead bench: `n` rounds of `k` allocations of `size` bytes, then their frees.
fn alloc_bench(n: u32, k: u32, size: usize) callconv(.c) u32 {
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
fn heap_fill(count: usize, size: usize, tag: usize) callconv(.c) void {
    mem.enter();
    const saved = lib.alloc.OWNER;
    // A free must come from the owner (the owner check at free).
    lib.alloc.OWNER = FILL_TAG;
    for (0..FILLED) |i| lib.alloc.hostDealloc(FILL[i]);
    // The task slot of the tag goes back too: the check of 12d wants each slot in use to be a waiting task.
    _ = lib.alloc.taskEnd(FILL_TAG);
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
fn walk_bench(owner: usize) callconv(.c) usize {
    mem.enter();
    return lib.alloc.freeOwner(owner) orelse std.math.maxInt(usize);
}

fn task_waiting() callconv(.c) u32 {
    return TASK_WAITING;
}
fn task_saved() callconv(.c) usize {
    return TASK_SAVED;
}
fn task_saved_max() callconv(.c) usize {
    return TASK_SAVED_MAX;
}
fn task_saved_peak() callconv(.c) usize {
    return TASK_SAVED_PEAK;
}
fn task_waits() callconv(.c) u32 {
    return TASK_WAITS;
}
/// Zero the copy counters, before a measured run.
fn stats_reset() callconv(.c) void {
    mem.enter();
    TASK_SAVED_MAX = 0;
    TASK_SAVED_PEAK = 0;
    TASK_WAITS = 0;
}
/// The copy work of `iters` waits of `len` bytes alone: alloc, copy out, copy back, free.
/// It copies the bytes at [4096, 4096 + len), inside the stack area.
fn copy_bench(len: usize, iters: u32) callconv(.c) u32 {
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
fn set_copy(on: u32) callconv(.c) void {
    mem.enter();
    COPY = on != 0;
}
/// PLAN.md H2, 4j: JS calls it at the idle point (after a passed idle check, 12e). 1: the heap
/// started again. 0: not done (a task runs or waits, or a block is live). Nothing is read or
/// changed then.
export fn idle_reset() u32 {
    if (TASK_TOP != 0 or lib.alloc.OWNER != 0 or TASK_WAITING != 0) return 0;
    mem.enter();
    return @intFromBool(lib.alloc.idleReset());
}

/// Test export (PLAN.md 4g): a wrong free that the allocator must catch. 1: a double free of a small
/// block (`double_frees`). 2: a free by a task that is not the owner (`dealloc_miss`). Both leave the
/// heap as it was.
fn bad_free(kind: u32) callconv(.c) void {
    mem.enter();
    const saved = lib.alloc.OWNER;
    defer lib.alloc.OWNER = saved;
    switch (kind) {
        1 => {
            // The second block keeps the page, so the second free finds the free mark.
            const a = lib.alloc.hostAllocFor(0, 24, 8);
            const b = lib.alloc.hostAllocFor(0, 24, 8);
            lib.alloc.hostDealloc(a);
            lib.alloc.hostDealloc(a);
            lib.alloc.hostDealloc(b);
        },
        2 => {
            lib.alloc.OWNER = 1_000_001;
            const a = lib.alloc.hostAlloc(24, 8);
            lib.alloc.OWNER = 1_000_002;
            lib.alloc.hostDealloc(a);
            lib.alloc.OWNER = 1_000_001;
            lib.alloc.hostDealloc(a);
            _ = lib.alloc.taskEnd(1_000_001);
        },
        else => {},
    }
}

/// Test export (PLAN.md 6d, 2a): the next allocation gives 0, from `roc_alloc` or `js_alloc`.
fn fail_next_alloc() callconv(.c) void {
    mem.enter();
    lib.alloc.FAIL_AT = 1;
}
/// Test export (PLAN.md 2c): allocation number `n` from now gives 0 (1: the next one).
fn fail_alloc_at(n: u32) callconv(.c) void {
    mem.enter();
    lib.alloc.FAIL_AT = n;
}
/// Test export: the allocations so far (all owners), to aim `fail_alloc_at`.
fn alloc_count() callconv(.c) u32 {
    return lib.alloc.ALLOCS;
}
/// Test export (PLAN.md 8e): the Native handles in use (all tasks).
fn native_slots() callconv(.c) u32 {
    return @intCast(lib.native.inUse(null));
}
/// Test export (PLAN.md 8e): the handles of task `from` become handles of task `to`. Returns how many.
fn native_reown(from: usize, to: usize) callconv(.c) u32 {
    return @intCast(lib.native.reown(from, to));
}
export fn live_bytes() usize {
    return lib.alloc.LIVE_BYTES;
}

// PLAN.md 7a: the test and bench exports. Only the bench host has them: the production host has
// no code for them (`platform/main.roc` lists the production exports, `bench/platform/main.roc` all).
comptime {
    if (BENCH) {
        const bench_exports = .{
            .{ "fault_next_wait", &fault_next_wait },
            .{ "set_wild", &set_wild },
            .{ "poke_wait", &poke_wait },
            .{ "leak_next", &leak_next },
            .{ "break_table", &break_table },
            .{ "alloc_bench", &alloc_bench },
            .{ "heap_fill", &heap_fill },
            .{ "walk_bench", &walk_bench },
            .{ "task_waiting", &task_waiting },
            .{ "task_saved", &task_saved },
            .{ "task_saved_max", &task_saved_max },
            .{ "task_saved_peak", &task_saved_peak },
            .{ "task_waits", &task_waits },
            .{ "stats_reset", &stats_reset },
            .{ "copy_bench", &copy_bench },
            .{ "set_copy", &set_copy },
            .{ "bad_free", &bad_free },
            .{ "fail_next_alloc", &fail_next_alloc },
            .{ "fail_alloc_at", &fail_alloc_at },
            .{ "alloc_count", &alloc_count },
            .{ "cbor_check", &cbor_check },
            .{ "cbor_echo", &cbor_echo },
            .{ "native_slots", &native_slots },
            .{ "native_reown", &native_reown },
        };
        for (bench_exports) |e| @export(e[1], .{ .name = e[0] });
    }
}
