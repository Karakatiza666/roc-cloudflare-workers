//! Probe variant: libzstd 1.5.7 (C, decompress only) behind the API of hostlib/native/zstd.zig.
//! Speed baseline only. `ZSTD_decompressStream` keeps its own window buffer (window + block), so the memory
//! of a small output from a big window frame is not the same as the std variant.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BLOCK_MAX: usize = 128 << 10;
pub const WINDOW_DEFAULT: u32 = 8 << 20;
pub const WINDOW_MAX: u32 = 8 << 20;
pub const PUSH_DEFAULT: u32 = 16 << 20;

pub const Error = error{ OutOfMemory, OutputLimit, WindowTooLarge, BadFrame, Unsupported, Truncated };

pub fn code(e: Error) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out_of_memory",
        error.OutputLimit => "output_limit",
        error.WindowTooLarge => "window_too_large",
        error.BadFrame => "bad_frame",
        error.Unsupported => "unsupported",
        error.Truncated => "truncated",
    };
}

const DStream = opaque {};
const InBuf = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const OutBuf = extern struct { dst: ?*anyopaque, size: usize, pos: usize };
const CustomMem = extern struct {
    alloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    opaque_: ?*anyopaque,
};
extern fn ZSTD_createDStream_advanced(mem: CustomMem) ?*DStream;
extern fn ZSTD_freeDStream(s: *DStream) usize;
extern fn ZSTD_DCtx_setParameter(s: *DStream, p: c_int, v: c_int) usize;
extern fn ZSTD_decompressStream(s: *DStream, out: *OutBuf, in: *InBuf) usize;
extern fn ZSTD_isError(r: usize) c_uint;
extern fn ZSTD_getErrorCode(r: usize) c_int;
const ZSTD_d_windowLogMax: c_int = 100;

// libzstd gets the allocator through customMem, so the libc ones are never called.
export fn malloc(_: usize) ?*anyopaque {
    @trap();
}
export fn calloc(_: usize, _: usize) ?*anyopaque {
    @trap();
}
export fn free(_: ?*anyopaque) void {
    @trap();
}

const HDR = 16;
fn cAlloc(o: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque {
    const a: *const Allocator = @ptrCast(@alignCast(o.?));
    const b = a.alignedAlloc(u8, .@"16", n + HDR) catch return null;
    std.mem.writeInt(usize, b[0..@sizeOf(usize)], n + HDR, .little);
    return b.ptr + HDR;
}
fn cFree(o: ?*anyopaque, p: ?*anyopaque) callconv(.c) void {
    const q = p orelse return;
    const a: *const Allocator = @ptrCast(@alignCast(o.?));
    const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(q)) - HDR);
    const n = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    a.free(base[0..n]);
}

fn mapErr(r: usize) Error {
    return switch (ZSTD_getErrorCode(r)) {
        16 => error.WindowTooLarge,
        64 => error.OutOfMemory,
        32, 30 => error.Unsupported,
        else => error.BadFrame,
    };
}

fn logCeil(n: u32) c_int {
    return @intCast(std.math.log2_int_ceil(u32, @max(n, 1 << 10)));
}

pub const Stream = struct {
    a: Allocator,
    ds: *DStream,
    push_limit: usize,
    last: usize = 1,
    total_in: usize = 0,
    failed: ?Error = null,

    pub fn open(a: Allocator, window_limit: u32, push_limit: u32) Error!*Stream {
        const s = try a.create(Stream);
        errdefer a.destroy(s);
        s.* = .{ .a = a, .ds = undefined, .push_limit = push_limit };
        s.ds = ZSTD_createDStream_advanced(.{ .alloc = cAlloc, .free = cFree, .opaque_ = @ptrCast(&s.a) }) orelse return error.OutOfMemory;
        _ = ZSTD_DCtx_setParameter(s.ds, ZSTD_d_windowLogMax, logCeil(@min(window_limit, WINDOW_MAX)));
        return s;
    }

    pub fn deinit(s: *Stream) void {
        _ = ZSTD_freeDStream(s.ds);
        s.a.destroy(s);
    }

    pub fn held(_: *const Stream) usize {
        return @sizeOf(Stream);
    }

    fn fail(s: *Stream, e: Error) Error {
        s.failed = e;
        return e;
    }

    pub fn push(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8)) Error!void {
        if (s.failed) |e| return e;
        s.total_in += chunk.len;
        var in: InBuf = .{ .src = chunk.ptr, .size = chunk.len, .pos = 0 };
        while (true) {
            out.ensureUnusedCapacity(s.a, BLOCK_MAX) catch return s.fail(error.OutOfMemory);
            const room = out.allocatedSlice()[out.items.len..];
            var o: OutBuf = .{ .dst = room.ptr, .size = room.len, .pos = 0 };
            const r = ZSTD_decompressStream(s.ds, &o, &in);
            if (ZSTD_isError(r) != 0) return s.fail(mapErr(r));
            s.last = r;
            out.items.len += o.pos;
            if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);
            if (in.pos == in.size and o.pos < o.size) break;
        }
    }

    pub fn finish(s: *Stream) Error!void {
        if (s.failed) |e| return e;
        if (s.total_in == 0 or s.last != 0) return error.Truncated;
    }
};

pub fn decode(a: Allocator, input: []const u8, max_out: usize) Error![]u8 {
    const s = try Stream.open(a, WINDOW_MAX, @intCast(@min(max_out, std.math.maxInt(u32))));
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try s.push(input, &out);
    try s.finish();
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}
