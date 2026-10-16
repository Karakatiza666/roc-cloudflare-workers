//! zstd for the Native ops (API.md 8, PLAN.md 8e), on `std.compress.zstd`.
//! `decode`: the whole input to one buffer, with an output limit. The window costs no memory.
//! `Stream`: push chunks of compressed input, get the output of each push. Memory: the window of the
//! frame (at most `window_limit`, grown with the output) + slack + one pending block (128 KB) + the decoder state.
//! Both: about 256 KB of stack while a block decodes (std keeps two 128 KB buffers on the stack).
//! std does not check the frame checksum (its `verify_checksum` panics). The caller hashes the archive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const zstd = std.compress.zstd;
const Decompress = zstd.Decompress;
const Header = Decompress.Frame.Zstandard.Header;

/// The largest block of a frame, and the free space that std wants before each block.
pub const BLOCK_MAX: usize = zstd.block_size_max;
/// Window limit when the caller gives none (the size that the zstd standard says all decoders must take).
pub const WINDOW_DEFAULT: u32 = 8 << 20;
/// The hardest limit: a window above it is refused, whatever the caller asks.
/// Packages from `roc bundle` have 2 MiB or less. A larger window does not fit next to the other tasks in 128 MB.
pub const WINDOW_MAX: u32 = 8 << 20;
/// Output of one push, when the caller gives no limit.
pub const PUSH_DEFAULT: u32 = 16 << 20;

pub const Error = error{
    OutOfMemory,
    /// The output is more than the limit.
    OutputLimit,
    /// The frame says it needs a window above the limit.
    WindowTooLarge,
    /// The bytes are not a valid frame.
    BadFrame,
    /// A dictionary frame (std does not take them).
    Unsupported,
    /// The input ends inside a frame, or it is empty.
    Truncated,
};

/// A short code for each error: the bytes of a status 1 result.
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

fn mapStd(e: ?Decompress.Error) Error {
    return switch (e orelse return error.BadFrame) {
        error.WindowOversize => error.WindowTooLarge,
        error.DictionaryIdFlagUnsupported => error.Unsupported,
        error.EndOfStream => error.Truncated,
        else => error.BadFrame,
    };
}

// ---------------------------------------------------------------- frame header

const MAGIC: u32 = 0xFD2FB528;
fn skippable(m: u32) bool {
    return m >= 0x184D2A50 and m <= 0x184D2A5F;
}

const Head = struct { len: usize, window: u64, content: ?u64, checksum: bool };

/// The header of the frame that starts at `d[0]` (the magic). Null: `d` is too short.
fn parseHead(d: []const u8) Error!?Head {
    if (d.len < 5) return null;
    if (std.mem.readInt(u32, d[0..4], .little) != MAGIC) return error.BadFrame;
    var r: Reader = .fixed(d[4..]);
    const h = Header.decode(&r) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return error.BadFrame,
    };
    return .{
        .len = 4 + r.seek,
        .window = h.windowSize() orelse return error.BadFrame,
        .content = h.content_size,
        .checksum = h.descriptor.content_checksum_flag,
    };
}

// ---------------------------------------------------------------- one frame, output limit

/// The buffer of `decode`: it grows as the output grows, never above `max_out` plus one block,
/// and holds the whole output, so it is also the window.
const Sink = struct {
    w: Writer,
    a: Allocator,
    max_out: usize,
    /// The sum of the content sizes that the frame headers declare (0: none): the first size to get.
    hint: usize = 0,
    oom: bool = false,

    const vtable: Writer.VTable = .{ .drain = drain, .rebase = rebase };

    fn init(a: Allocator, max_out: usize) Sink {
        return .{ .w = .{ .buffer = &.{}, .vtable = &vtable }, .a = a, .max_out = max_out };
    }

    /// Room for `n` more bytes after `end`, with `keep` bytes before `end` that stay.
    fn room(s: *Sink, keep: usize, n: usize) Writer.Error!void {
        const w = &s.w;
        const need = @max(std.math.add(usize, keep, n) catch return error.WriteFailed, std.math.add(usize, w.end, n) catch return error.WriteFailed);
        if (w.buffer.len >= need) return;
        // The window can be more than `max_out` (a small output with a big window): then the buffer holds the window.
        const lim = @max(s.max_out, keep) + BLOCK_MAX;
        if (need > lim) return error.WriteFailed;
        const want = @min(lim, @max(need, s.hint + BLOCK_MAX, w.buffer.len * 2, 64 << 10));
        const nb = s.a.realloc(w.buffer, want) catch {
            // One more try with the exact size before the failure.
            w.buffer = s.a.realloc(w.buffer, need) catch {
                s.oom = true;
                return error.WriteFailed;
            };
            return;
        };
        w.buffer = nb;
    }

    fn rebase(w: *Writer, keep: usize, n: usize) Writer.Error!void {
        const s: *Sink = @fieldParentPtr("w", w);
        return s.room(keep, n);
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *Sink = @fieldParentPtr("w", w);
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |b| count += b.len;
        count += data[data.len - 1].len * splat;
        try s.room(0, count);
        for (data[0 .. data.len - 1]) |b| {
            @memcpy(w.buffer[w.end..][0..b.len], b);
            w.end += b.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            @memcpy(w.buffer[w.end..][0..last.len], last);
            w.end += last.len;
        }
        return count;
    }
};

/// Decode `input` (frames, back to back) into a new buffer of the owner of `a`. Output over `max_out`
/// is `error.OutputLimit`: a declared content size over the limit stops before any decode, else the
/// decode stops after the block that crosses it. Peak memory: the output (at most `max_out` plus one
/// block, with growth steps) plus 256 KB of stack. The window of the frame costs nothing, because the
/// buffer is the whole output.
///
/// std checks the window of a frame in `Frame.init` and also uses the same number as the "keep" length
/// of its writer, which would make us hold a buffer of the window size (8 MB for a frame from a pipe)
/// for any output. So each frame starts with a call that sees only its header: `Frame.init` runs with
/// the real window, the block read then fails at the end of the input, and the state stays
/// `in_frame`. Then `window_len` is 0 and the input is the rest. A test guards this (std can change).
pub fn decode(a: Allocator, input: []const u8, max_out: usize) Error![]u8 {
    var in: Reader = .fixed(input);
    var base: usize = 0;
    var d: Decompress = .init(&in, &.{}, .{ .window_len = std.math.maxInt(u32) });
    var sink: Sink = .init(a, max_out);
    errdefer a.free(sink.w.buffer);
    var declared: usize = 0;
    var frames: usize = 0;
    while (true) {
        if (d.state == .new_frame) {
            const at = base + in.seek;
            const rest = input[at..];
            if (rest.len > 0 and rest.len < 4) return error.Truncated; // std says BadMagic
            if (rest.len >= 4 and !skippable(std.mem.readInt(u32, rest[0..4], .little))) {
                const h = (try parseHead(rest)) orelse return error.Truncated;
                if (h.content) |c| {
                    declared = std.math.add(usize, declared, std.math.cast(usize, c) orelse return error.OutputLimit) catch return error.OutputLimit;
                    if (declared > max_out) return error.OutputLimit;
                    sink.hint = declared;
                }
                d.window_len = std.math.cast(u32, h.window) orelse return error.WindowTooLarge;
                in = .fixed(rest[0..h.len]);
                base = at;
                _ = d.reader.stream(&sink.w, .unlimited) catch |e| switch (e) {
                    error.ReadFailed => if (d.err) |de| if (de != error.EndOfStream) return mapStd(de),
                    else => return error.Truncated,
                };
                d.err = null;
                d.window_len = 0;
                base = at + h.len;
                in = .fixed(input[base..]);
                frames += 1;
            }
        }
        _ = d.reader.stream(&sink.w, .unlimited) catch |e| switch (e) {
            error.EndOfStream => break,
            error.WriteFailed => return if (sink.oom) error.OutOfMemory else error.OutputLimit,
            error.ReadFailed => return mapStd(d.err),
        };
        if (sink.w.end > max_out) return error.OutputLimit;
    }
    if (frames == 0) return error.Truncated;
    const out = sink.w.buffer[0..sink.w.end];
    if (out.len == sink.w.buffer.len) return out;
    return a.realloc(sink.w.buffer, out.len) catch out;
}

// ---------------------------------------------------------------- stream

/// What to do with the bytes at the start of the pending or the chunk data.
const Need = union(enum) {
    /// Not enough bytes: the next least total that lets the parse go on.
    more: usize,
    /// A whole unit (the frame header when it starts a frame, a block, the checksum after the last block).
    unit: struct { len: usize, last: bool },
    /// A skippable frame: its whole length.
    skip: usize,
};

pub const Stream = struct {
    a: Allocator,
    in: Reader = undefined,
    d: Decompress = undefined,
    /// The window and the room for the next blocks. It grows with the output up to `buf_max`.
    buf: []u8 = &.{},
    buf_max: usize = 0,
    /// The start of a unit that did not fit in a chunk.
    pend: []u8 = &.{},
    pend_len: usize = 0,
    skip_left: usize = 0,
    in_frame: bool = false,
    checksum: bool = false,
    window_limit: u32,
    push_limit: usize,
    failed: ?Error = null,
    total_in: usize = 0,

    pub fn open(a: Allocator, window_limit: u32, push_limit: u32) Error!*Stream {
        const s = try a.create(Stream);
        s.* = .{ .a = a, .window_limit = @min(window_limit, WINDOW_MAX), .push_limit = push_limit };
        return s;
    }

    pub fn deinit(s: *Stream) void {
        const a = s.a;
        if (s.buf.len != 0) a.free(s.buf);
        if (s.pend.len != 0) a.free(s.pend);
        a.destroy(s);
    }

    /// Bytes held now (the window, the pending block, the struct).
    pub fn held(s: *const Stream) usize {
        return s.buf.len + s.pend.len + @sizeOf(Stream);
    }

    fn probe(s: *const Stream, d: []const u8) Error!Need {
        var off: usize = 0;
        var checksum = s.checksum;
        if (!s.in_frame) {
            if (d.len < 4) return .{ .more = 4 };
            const magic = std.mem.readInt(u32, d[0..4], .little);
            if (skippable(magic)) {
                if (d.len < 8) return .{ .more = 8 };
                return .{ .skip = 8 + @as(usize, std.mem.readInt(u32, d[4..8], .little)) };
            }
            if (magic != MAGIC) return error.BadFrame;
            if (d.len < 5) return .{ .more = 5 };
            // Header size from the descriptor byte (the zstd format, "Frame_Header_Descriptor").
            const desc = d[4];
            const single = desc & 0x20 != 0;
            const dict: usize = switch (desc & 3) {
                0 => 0,
                1 => 1,
                2 => 2,
                else => 4,
            };
            const fcs: usize = switch (desc >> 6) {
                0 => @intFromBool(single),
                1 => 2,
                2 => 4,
                else => 8,
            };
            off = 5 + @as(usize, @intFromBool(!single)) + dict + fcs;
            if (d.len < off) return .{ .more = off };
            checksum = desc & 0x04 != 0;
        }
        if (d.len < off + 3) return .{ .more = off + 3 };
        const bh = std.mem.readInt(u24, d[off..][0..3], .little);
        const last = bh & 1 != 0;
        const typ = (bh >> 1) & 3;
        const size: usize = bh >> 3;
        if (typ == 3 or size > BLOCK_MAX) return error.BadFrame;
        const body: usize = if (typ == 1) 1 else size;
        const total = off + 3 + body + @as(usize, if (last and checksum) 4 else 0);
        if (d.len < total) return .{ .more = total };
        return .{ .unit = .{ .len = total, .last = last } };
    }

    fn startFrame(s: *Stream, unit: []const u8) Error!void {
        const h = (try parseHead(unit)) orelse return error.BadFrame;
        if (h.window > s.window_limit) return error.WindowTooLarge;
        const w: usize = @intCast(h.window);
        // Slack: the buffer moves its window down when less than one block is free, so more slack means fewer moves.
        const slack = std.math.clamp(w / 4, BLOCK_MAX, 2 << 20);
        s.buf_max = w + slack;
        // A frame from a pipe says 8 MB of window for a small output. So the buffer starts small and
        // grows (`room`) until it has the whole window.
        if (s.buf.len < BLOCK_MAX * 2) {
            if (s.buf.len != 0) s.a.free(s.buf);
            s.buf = &.{};
            s.buf = try s.a.alloc(u8, @min(s.buf_max, BLOCK_MAX * 2));
        }
        // `init` only compares the length with window + block (an assert) and does not touch the bytes.
        // It does so before the buffer has grown to that size, so it gets the full length once and then the real buffer.
        s.d = .init(&s.in, s.buf.ptr[0..s.buf_max], .{ .window_len = @intCast(w) });
        s.d.reader.buffer = s.buf;
        s.checksum = h.checksum;
    }

    /// std wants one free block before it decodes. While the buffer is below its full size, grow it
    /// (std moves the window down only in a full size buffer: its check is `buffer >= window + block`).
    fn room(s: *Stream) Error!void {
        const r = &s.d.reader;
        if (r.buffer.len - r.end >= BLOCK_MAX or r.buffer.len >= s.buf_max) return;
        const want = @min(s.buf_max, @max(r.end + BLOCK_MAX, r.buffer.len * 2));
        s.buf = try s.a.realloc(s.buf, want);
        r.buffer = s.buf;
    }

    fn decodeUnit(s: *Stream, unit: []const u8, last: bool, out: *std.ArrayList(u8)) Error!void {
        if (!s.in_frame) try s.startFrame(unit);
        s.in = .fixed(unit);
        try s.room();
        const r = &s.d.reader;
        var none: [0][]u8 = .{};
        _ = r.vtable.readVec(r, &none) catch |e| switch (e) {
            error.ReadFailed => return mapStd(s.d.err),
            error.EndOfStream => return error.Truncated,
        };
        if (s.in.seek != unit.len) return error.BadFrame;
        try out.appendSlice(s.a, r.buffer[r.seek..r.end]);
        r.seek = r.end;
        s.in_frame = !last;
    }

    fn pendGrow(s: *Stream, n: usize) Error!void {
        if (s.pend.len >= n) return;
        s.pend = try s.a.realloc(s.pend, @max(n, 64));
    }

    fn fail(s: *Stream, e: Error) Error {
        s.failed = e;
        return e;
    }

    /// Feed `chunk`. The output of the blocks that are whole is appended to `out`. After an error the
    /// stream is dead: each call gives the same error.
    pub fn push(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8)) Error!void {
        if (s.failed) |e| return e;
        s.total_in += chunk.len;
        var pos: usize = 0;
        while (true) {
            if (s.skip_left > 0) {
                const n = @min(s.skip_left, chunk.len - pos);
                s.skip_left -= n;
                pos += n;
                if (s.skip_left > 0) break;
                continue;
            }
            if (s.pend_len > 0) {
                const need = s.probe(s.pend[0..s.pend_len]) catch |e| return s.fail(e);
                switch (need) {
                    .unit => |u| {
                        s.decodeUnit(s.pend[0..u.len], u.last, out) catch |e| return s.fail(e);
                        s.pend_len = 0;
                    },
                    .skip => |t| {
                        s.skip_left = t - s.pend_len;
                        s.pend_len = 0;
                    },
                    .more => |m| {
                        if (pos == chunk.len) break;
                        const n = @min(chunk.len - pos, m - s.pend_len);
                        s.pendGrow(m) catch |e| return s.fail(e);
                        @memcpy(s.pend[s.pend_len..][0..n], chunk[pos..][0..n]);
                        s.pend_len += n;
                        pos += n;
                    },
                }
            } else {
                if (pos == chunk.len) break;
                const rest = chunk[pos..];
                const need = s.probe(rest) catch |e| return s.fail(e);
                switch (need) {
                    .unit => |u| {
                        s.decodeUnit(rest[0..u.len], u.last, out) catch |e| return s.fail(e);
                        pos += u.len;
                    },
                    .skip => |t| {
                        const n = @min(t, rest.len);
                        s.skip_left = t - n;
                        pos += n;
                    },
                    .more => |m| {
                        s.pendGrow(m) catch |e| return s.fail(e);
                        @memcpy(s.pend[0..rest.len], rest);
                        s.pend_len = rest.len;
                        pos = chunk.len;
                    },
                }
            }
            if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);
        }
    }

    /// The end of the input: it must be at the end of a frame.
    pub fn finish(s: *Stream) Error!void {
        if (s.failed) |e| return e;
        if (s.total_in == 0 or s.in_frame or s.pend_len != 0 or s.skip_left != 0) return error.Truncated;
    }
};
