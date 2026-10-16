//! The Native ops of API.md 8 (PLAN.md 8e): `native!(op, bytes)` calls `call`.
//! zstd (one frame with an output limit, and streams), BLAKE3 and SHA-256 with state across calls.
//! The state of a stream or a hash is a handle: a slot in a table of the instance. A slot records
//! its owner (the task that made it). Another task, a closed handle or a handle of another kind is
//! status 1. `endTask` drops the slots of a task: the bridge calls it where it frees the memory of the task.
//! No Roc and no wasm code here: the allocator and the owner are arguments, so `zig test` runs it.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const zstd = @import("zstd.zig");
const Blake3 = std.crypto.hash.Blake3;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The op numbers (the `U32` argument of `native!`).
pub const Op = enum(u32) {
    zstd_decode = 1,
    zstd_stream_open = 2,
    zstd_stream_push = 3,
    zstd_stream_close = 4,
    blake3_new = 5,
    blake3_update = 6,
    blake3_final = 7,
    sha256_new = 8,
    sha256_update = 9,
    sha256_final = 10,
    _,
};

/// Slots in the table of the instance, and the most that one task can hold.
pub const MAX_HANDLES = 64;
pub const MAX_PER_TASK = 16;
pub const MAX_STREAMS_PER_TASK = 4;

/// Status 0: `bytes` is the answer. Status 1: `bytes` is a short code (a static string, `owned` is false).
/// Status 4: out of memory (API.md 4.1): the bridge makes a clean OOM trap for the task, as for a failed `roc_alloc`.
pub const Result = struct {
    status: u8,
    bytes: []const u8,
    /// `bytes` is a block of the allocator: the caller frees it with `release`.
    owned: bool,

    pub fn release(r: Result, a: Allocator) void {
        if (r.owned) a.free(r.bytes);
    }
};

const Err = error{ OutOfMemory, BadArgument, BadHandle, WrongTask, WrongKind, TooManyHandles, NoTask } || zstd.Error;

fn errCode(e: Err) []const u8 {
    return switch (e) {
        error.BadArgument => "bad_argument",
        error.BadHandle => "bad_handle",
        error.WrongTask => "wrong_task",
        error.WrongKind => "wrong_kind",
        error.TooManyHandles => "too_many_handles",
        error.NoTask => "no_task",
        inline else => |z| zstd.code(z),
    };
}

// ---------------------------------------------------------------- table

const Kind = enum { zstd, blake3, sha256 };
const Slot = struct {
    used: bool = false,
    /// Goes up at each close, so an old handle never matches a new slot.
    gen: u24 = 0,
    owner: usize = 0,
    kind: Kind = .zstd,
    ptr: usize = 0,
};
var table: [MAX_HANDLES]Slot = @splat(.{});

/// A handle is `gen << 8 | (index + 1)`: never 0.
fn handleOf(i: usize) u32 {
    return (@as(u32, table[i].gen) << 8) | @as(u32, @intCast(i + 1));
}

fn lookup(handle: u32, owner: usize, kind: Kind) Err!*Slot {
    const lo = handle & 0xFF;
    if (lo == 0 or lo > MAX_HANDLES) return error.BadHandle;
    const s = &table[lo - 1];
    if (!s.used or s.gen != handle >> 8) return error.BadHandle;
    if (s.owner != owner) return error.WrongTask;
    if (s.kind != kind) return error.WrongKind;
    return s;
}

fn insert(owner: usize, kind: Kind, ptr: usize) Err!u32 {
    // Owner 0 is the host: `endTask` never frees its slots.
    if (owner == 0) return error.NoTask;
    var mine: usize = 0;
    var streams: usize = 0;
    var free: ?usize = null;
    for (&table, 0..) |*s, i| {
        if (!s.used) {
            if (free == null) free = i;
        } else if (s.owner == owner) {
            mine += 1;
            if (s.kind == .zstd) streams += 1;
        }
    }
    if (mine >= MAX_PER_TASK or free == null) return error.TooManyHandles;
    if (kind == .zstd and streams >= MAX_STREAMS_PER_TASK) return error.TooManyHandles;
    const i = free.?;
    table[i] = .{ .used = true, .gen = table[i].gen, .owner = owner, .kind = kind, .ptr = ptr };
    return handleOf(i);
}

fn close(s: *Slot) void {
    s.used = false;
    s.gen +%= 1;
    s.ptr = 0;
}

/// Slots in use, and the slots of `owner` (for tests and for the log).
pub fn inUse(owner: ?usize) usize {
    var n: usize = 0;
    for (&table) |*s| if (s.used and (owner == null or s.owner == owner.?)) {
        n += 1;
    };
    return n;
}

/// Test hook (the bench host only, PLAN.md 8e): the slots of `from` become slots of `to`, so a handle that
/// `from` made is a handle of another task. Returns the number of slots moved.
pub fn reown(from: usize, to: usize) usize {
    var n: usize = 0;
    for (&table) |*s| if (s.used and s.owner == from) {
        s.owner = to;
        n += 1;
    };
    return n;
}

pub const EndMode = enum {
    /// Drop the slots only. The blocks are of the task: `freeOwner` or `taskDone` of the allocator frees them.
    forget,
    /// Drop the slots and free each block with `a` (an allocator that is not owner tagged, tests).
    free,
};

/// The task `owner` ended: after a return, a clean trap or a cancel. Call it before the allocator frees the owner.
pub fn endTask(a: Allocator, owner: usize, mode: EndMode) void {
    if (owner == 0) return;
    for (&table) |*s| if (s.used and s.owner == owner) {
        if (mode == .free) destroy(a, s);
        close(s);
    };
}

fn destroy(a: Allocator, s: *const Slot) void {
    switch (s.kind) {
        .zstd => @as(*zstd.Stream, @ptrFromInt(s.ptr)).deinit(),
        .blake3 => a.destroy(@as(*Blake3, @ptrFromInt(s.ptr))),
        .sha256 => a.destroy(@as(*Sha256, @ptrFromInt(s.ptr))),
    }
}

// ---------------------------------------------------------------- ops

fn u32At(in: []const u8, at: usize) Err!u32 {
    if (in.len < at + 4) return error.BadArgument;
    return std.mem.readInt(u32, in[at..][0..4], .little);
}

fn bytes(b: []const u8) Result {
    return .{ .status = 0, .bytes = b, .owned = b.len != 0 };
}
const empty: Result = .{ .status = 0, .bytes = &.{}, .owned = false };

fn hashNew(a: Allocator, owner: usize, comptime T: type, kind: Kind, init: T) Err!Result {
    // The slot is the last step: no later step can fail and leave a slot that points at freed memory.
    const out = try a.alloc(u8, 4);
    errdefer a.free(out);
    const h = try a.create(T);
    errdefer a.destroy(h);
    h.* = init;
    std.mem.writeInt(u32, out[0..4], try insert(owner, kind, @intFromPtr(h)), .little);
    return bytes(out);
}

fn hashUpdate(owner: usize, comptime T: type, kind: Kind, in: []const u8) Err!Result {
    const s = try lookup(try u32At(in, 0), owner, kind);
    @as(*T, @ptrFromInt(s.ptr)).update(in[4..]);
    return empty;
}

fn hashFinal(a: Allocator, owner: usize, comptime T: type, kind: Kind, in: []const u8) Err!Result {
    const s = try lookup(try u32At(in, 0), owner, kind);
    const h: *T = @ptrFromInt(s.ptr);
    const out = try a.alloc(u8, T.digest_length);
    h.final(out[0..T.digest_length]);
    close(s);
    a.destroy(h);
    return bytes(out);
}

fn run(a: Allocator, owner: usize, op: u32, in: []const u8) Err!Result {
    const o: Op = @fromBackingInt(@intCast(op));
    switch (o) {
        .zstd_decode => {
            const max_out = try u32At(in, 0);
            return bytes(try zstd.decode(a, in[4..], max_out));
        },
        .zstd_stream_open => {
            var window: u32 = zstd.WINDOW_DEFAULT;
            var push: u32 = zstd.PUSH_DEFAULT;
            if (in.len != 0) {
                // 0 means the default. More than the hard window limit is an error, not a silent cut.
                const w = try u32At(in, 0);
                if (w > zstd.WINDOW_MAX) return error.BadArgument;
                if (w != 0) window = w;
                if (in.len > 4) {
                    const p = try u32At(in, 4);
                    if (p != 0) push = p;
                }
            }
            const out = try a.alloc(u8, 4);
            errdefer a.free(out);
            const s = try zstd.Stream.open(a, window, push);
            errdefer s.deinit();
            std.mem.writeInt(u32, out[0..4], try insert(owner, .zstd, @intFromPtr(s)), .little);
            return bytes(out);
        },
        .zstd_stream_push => {
            const s = try lookup(try u32At(in, 0), owner, .zstd);
            const st: *zstd.Stream = @ptrFromInt(s.ptr);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(a);
            // A failed stream stays open, so the next call gives the same error. `close` frees it.
            try st.push(in[4..], &out);
            return bytes(try out.toOwnedSlice(a));
        },
        .zstd_stream_close => {
            const s = try lookup(try u32At(in, 0), owner, .zstd);
            const st: *zstd.Stream = @ptrFromInt(s.ptr);
            const r = st.finish();
            st.deinit();
            close(s);
            try r;
            return empty;
        },
        .blake3_new => return hashNew(a, owner, Blake3, .blake3, Blake3.init(.{})),
        .blake3_update => return hashUpdate(owner, Blake3, .blake3, in),
        .blake3_final => return hashFinal(a, owner, Blake3, .blake3, in),
        .sha256_new => return hashNew(a, owner, Sha256, .sha256, Sha256.init(.{})),
        .sha256_update => return hashUpdate(owner, Sha256, .sha256, in),
        .sha256_final => return hashFinal(a, owner, Sha256, .sha256, in),
        _ => return error.BadArgument,
    }
}

/// The stack that an op can use below its caller, in bytes. zstd: about 274 KB while a block decodes (std keeps two
/// 128 KB arrays on the stack, research/native/README.md 7), so 300 KB. BLAKE3 14 KB and SHA-256 9 KB: 16 KB.
/// The bridge reserves it before the call (`canary.reserve`): a frame that would pass the canary is a clean trap.
pub fn stackNeed(op: u32) usize {
    return switch (@as(Op, @fromBackingInt(op))) {
        .zstd_decode, .zstd_stream_push => 300 * 1024,
        else => 16 * 1024,
    };
}

/// One op. `a` allocates for the task that runs (the real allocator tags the block with `alloc.OWNER`), and
/// `owner` is that task. The result block is of `a`: the bridge copies it into a Roc list and calls `release`.
pub fn call(a: Allocator, owner: usize, op: u32, in: []const u8) Result {
    return run(a, owner, op, in) catch |e| switch (e) {
        error.OutOfMemory => .{ .status = 4, .bytes = "out_of_memory", .owned = false },
        else => .{ .status = 1, .bytes = errCode(e), .owned = false },
    };
}
