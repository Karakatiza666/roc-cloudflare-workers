//! Probe variant: zaxified/zig-libs modules/zstd (pure Zig port of libzstd 1.5.7) behind the API of hostlib/native/zstd.zig. Speed probe only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Z = @import("zz");

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

fn mapErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory, error.MemoryAllocation, error.AllocationFailure => error.OutOfMemory,
        error.WindowTooLarge, error.FrameParameterWindowTooLarge => error.WindowTooLarge,
        error.DictionaryWrong => error.Unsupported,
        else => error.BadFrame,
    };
}

pub const Stream = struct {
    a: Allocator,
    d: Z.DecompressStream,
    push_limit: usize,
    last: usize = 1,
    total_in: usize = 0,
    failed: ?Error = null,

    pub fn open(a: Allocator, window_limit: u32, push_limit: u32) Error!*Stream {
        const s = try a.create(Stream);
        errdefer a.destroy(s);
        s.* = .{ .a = a, .d = undefined, .push_limit = push_limit };
        s.d = Z.DecompressStream.init(a, .{ .max_window_size = @min(window_limit, WINDOW_MAX), .ignore_checksum = true }) catch return error.OutOfMemory;
        return s;
    }
    pub fn deinit(s: *Stream) void {
        s.d.deinit();
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
        var in: Z.InBuffer = .{ .src = chunk };
        while (true) {
            out.ensureUnusedCapacity(s.a, BLOCK_MAX) catch return s.fail(error.OutOfMemory);
            const room = out.allocatedSlice()[out.items.len..];
            var o: Z.OutBuffer = .{ .dst = room };
            s.last = s.d.decompressStream(&o, &in) catch |e| return s.fail(mapErr(e));
            out.items.len += o.pos;
            if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);
            if (in.pos == in.src.len and o.pos < o.dst.len) break;
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
