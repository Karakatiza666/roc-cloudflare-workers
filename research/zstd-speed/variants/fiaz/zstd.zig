//! Probe variant: muhammad-fiaz/zstd.zig 0.0.5 (pure Zig) behind the API of hostlib/native/zstd.zig. Speed probe only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Z = @import("zstdzig");

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
        error.WindowTooLarge => error.WindowTooLarge,
        error.DictionaryWrong => error.Unsupported,
        else => error.BadFrame,
    };
}

pub const Stream = struct {
    a: Allocator,
    d: Z.StreamingDecompressor,
    push_limit: usize,
    more: bool = true,
    total_in: usize = 0,
    failed: ?Error = null,

    pub fn open(a: Allocator, window_limit: u32, push_limit: u32) Error!*Stream {
        const s = try a.create(Stream);
        s.* = .{ .a = a, .d = .init(a), .push_limit = push_limit };
        s.d.setMaxWindowSize(@min(window_limit, WINDOW_MAX));
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
        var in = chunk;
        while (true) {
            out.ensureUnusedCapacity(s.a, BLOCK_MAX) catch return s.fail(error.OutOfMemory);
            const room = out.allocatedSlice()[out.items.len..];
            const r = s.d.decompressStream(room, in) catch |e| return s.fail(mapErr(e));
            in = &.{};
            s.more = r.needsMore;
            out.items.len += r.outProduced;
            if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);
            if (r.outProduced == 0) break;
        }
    }
    pub fn finish(s: *Stream) Error!void {
        if (s.failed) |e| return e;
        if (s.total_in == 0 or s.more) return error.Truncated;
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
