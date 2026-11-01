//! zstd for the Native ops (API.md 8, PLAN.md 8e). The decoder is the pure Zig port of the libzstd 1.5.7
//! decoder in `hostlib/zstd/` (module `zstd_dec`, built with ReleaseSafe: every bounds check is on; README there).
//! This file uses its piece by piece API (`ZSTD_decompressContinue`): it feeds the decoder one unit at a time
//! (the frame header, a block header, a block, the checksum) and gives it the output buffer, which is also the window.
//! `decode`: the whole input to one buffer, with an output limit. The window costs no memory.
//! `Stream`: push chunks of compressed input, get the output of each push. Memory: the window of the frame
//! (at most `window_limit`, grown with the output) + two blocks (256 KB) + one pending block (128 KB) + the decoder
//! state (about 160 KB).
//! The frame checksum (xxh64) is checked when the frame has one: a wrong checksum is `BadFrame`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Z = @import("zstd_dec");
const Dec = Z.Decompressor;
const State = @typeInfo(@FieldType(Dec, "st")).pointer.child;

/// The largest block of a frame, and the free space before each block.
pub const BLOCK_MAX: usize = Z.block_size_max;
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
    /// The bytes are not a valid frame (also a wrong checksum).
    BadFrame,
    /// A dictionary frame.
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

fn mapDec(e: Z.Error) Error {
    return switch (e) {
        error.FrameParameterWindowTooLarge => error.WindowTooLarge,
        error.DictionaryWrong => error.Unsupported,
        else => error.BadFrame,
    };
}

// ---------------------------------------------------------------- frame header

const MAGIC: u32 = 0xFD2FB528;
fn skippable(m: u32) bool {
    return m >= 0x184D2A50 and m <= 0x184D2A5F;
}
/// The header bytes before the size of the header is known (magic and descriptor), and the most there can be.
const HEAD_PREFIX = Z.frame_header_size_prefix;
const HEAD_MAX = 18;
/// The decoder can read this many bytes after the end of a match source (libzstd `WILDCOPY_OVERLENGTH`).
const WILDCOPY = 32;

const Head = struct { len: usize, window: u64, content: ?u64, dict: bool };

/// The header of the frame at `d[0]` (the magic is checked). Null: `d` is too short.
fn parseHead(d: []const u8) Error!?Head {
    if (d.len < HEAD_PREFIX) return null;
    if (std.mem.readInt(u32, d[0..4], .little) != MAGIC) return error.BadFrame;
    const h = switch (Z.getFrameHeader(d) catch |e| return mapDec(e)) {
        .need => return null,
        .header => |h| h,
    };
    return .{ .len = h.header_size, .window = h.window_size, .content = h.content_size, .dict = d[4] & 3 != 0 };
}

// ---------------------------------------------------------------- the decoder and its buffer

/// The state of the decoder, on the heap. `Dec.init` copies a default `State` (with its 128 KB literal buffer) from
/// a constant, which puts about 170 KB of zero bytes into the data of the host. So each field gets its default here,
/// and the large arrays (the literal buffer and the table cells, which the decoder writes before it reads) stay
/// undefined, as in the default. The field list is checked when the code compiles: a new version of the decoder
/// with other fields fails here.
fn newDec(a: Allocator) Error!Dec {
    comptime {
        const want = [_][]const u8{ "ll", "of", "ml", "huf", "rep", "ll_ptr", "of_ptr", "ml_ptr", "huf_ptr", "lit_entropy", "fse_entropy", "block_size_max", "lit_src", "lit_pos", "lit_end", "lit_buf" };
        const got = @typeInfo(State).@"struct".field_names;
        if (got.len != want.len) @compileError("zstd_dec: the fields of State changed");
        for (got, want) |f, w| if (!std.mem.eql(u8, f, w)) @compileError("zstd_dec: the fields of State changed: " ++ f);
    }
    const st = try a.create(State);
    initSmall(State, st);
    // As `Dec.init` (`fromState`) after its copy.
    st.huf_ptr = &st.huf;
    @memset(st.lit_buf[BLOCK_MAX..], 0);
    return .{ .gpa = a, .st = st, .options = .{} };
}

/// Each field of `p` gets its default value, except arrays of more than 64 bytes (undefined in the default) and
/// `huf_ptr` (undefined in the default).
/// A struct field gets the defaults of its own fields (the fields of `State` that are structs default to `.{}`).
fn initSmall(comptime T: type, p: *T) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        if (comptime std.mem.eql(u8, name, "huf_ptr")) {
            // Its default is undefined: `newDec` sets it.
        } else if (@typeInfo(F) == .@"struct") {
            initSmall(F, &@field(p, name));
        } else if (!(@typeInfo(F) == .array and @sizeOf(F) > 64)) {
            @field(p, name) = attrs.defaultValue(F).?;
        }
    }
}

/// The decoder keeps its history as the addresses of the start and the end of the output so far (libzstd's
/// `prefixStart` and `previousDstEnd`). The buffer moved from `old` to `new`: the history moves with it.
fn rebase(d: *Dec, old: usize, new: usize) Error!void {
    // The older segment (`ext`) is made only when the output goes back to the start of a full size stream buffer
    // (`Stream.room`), and a full size buffer does not move.
    if (d.ext.len != 0) return error.BadFrame;
    inline for (.{ "prefix_addr", "prev_end_addr" }) |f| {
        const p = @field(d, f);
        if (p != 0) @field(d, f) = new + (p - old);
    }
}

/// Feed one unit (exactly `nextSrcSizeToDecompress` bytes) and write its output after `buf[end]`. The caller has made
/// room for one block. Returns the number of bytes written.
fn feedUnit(d: *Dec, buf: []u8, end: usize, unit: []const u8) Error!usize {
    return d.decompressContinue(buf[end..], unit) catch |e| mapDec(e);
}

/// Start a frame: `hdr` is its whole header. The decoder takes the header in two units, as it asks.
fn begin(d: *Dec, buf: []u8, end: usize, hdr: []const u8) Error!void {
    d.begin();
    _ = try feedUnit(d, buf, end, hdr[0..HEAD_PREFIX]);
    if (hdr.len > HEAD_PREFIX) _ = try feedUnit(d, buf, end, hdr[HEAD_PREFIX..]);
}

// ---------------------------------------------------------------- one call, output limit

/// Decode `input` (frames, back to back) into a new buffer of the owner of `a`. Output over `max_out`
/// is `error.OutputLimit`: a declared content size over the limit stops before any decode, else the
/// decode stops after the block that crosses it. Peak memory: the output (at most `max_out` plus one
/// block, with growth steps) plus the decoder state (about 160 KB). The window of the frame costs nothing,
/// because the buffer is the whole output.
pub fn decode(a: Allocator, input: []const u8, max_out: usize) Error![]u8 {
    var dec: ?Dec = null;
    defer if (dec) |*x| x.deinit();
    var buf: []u8 = &.{};
    errdefer a.free(buf);
    var end: usize = 0;
    var hint: usize = 0;
    var declared: usize = 0;
    var frames: usize = 0;
    var at: usize = 0;
    const lim = std.math.add(usize, max_out, BLOCK_MAX) catch std.math.maxInt(usize);
    while (at < input.len) {
        const rest = input[at..];
        if (rest.len < 4) return error.Truncated;
        if (skippable(std.mem.readInt(u32, rest[0..4], .little))) {
            if (rest.len < 8) return error.Truncated;
            const n = 8 + @as(usize, std.mem.readInt(u32, rest[4..8], .little));
            if (rest.len < n) return error.Truncated;
            at += n;
            continue;
        }
        const h = (try parseHead(rest)) orelse return error.Truncated;
        if (h.content) |c| {
            declared = std.math.add(usize, declared, std.math.cast(usize, c) orelse return error.OutputLimit) catch return error.OutputLimit;
            if (declared > max_out) return error.OutputLimit;
            hint = declared;
        }
        if (h.window > std.math.maxInt(u32)) return error.WindowTooLarge;
        if (h.dict) return error.Unsupported;
        if (dec == null) dec = try newDec(a);
        const d = &dec.?;
        try begin(d, buf, end, rest[0..h.len]);
        at += h.len;
        frames += 1;
        while (true) {
            const n = d.nextSrcSizeToDecompress();
            if (n == 0) break;
            if (input.len - at < n) return error.Truncated;
            // Room for one block. The buffer grows, never above the limit plus one block.
            if (buf.len - end < BLOCK_MAX) {
                const need = end + BLOCK_MAX;
                if (need > lim) return error.OutputLimit;
                const want = @min(lim, @max(need, hint + BLOCK_MAX, buf.len * 2, 64 << 10));
                const old = @intFromPtr(buf.ptr);
                // One more try with the exact size before the failure.
                buf = a.realloc(buf, want) catch try a.realloc(buf, need);
                try rebase(d, old, @intFromPtr(buf.ptr));
            }
            end += try feedUnit(d, buf, end, input[at..][0..n]);
            at += n;
            if (end > max_out) return error.OutputLimit;
        }
    }
    if (frames == 0) return error.Truncated;
    if (end == buf.len) return buf;
    return a.realloc(buf, end) catch buf[0..end];
}

// ---------------------------------------------------------------- stream

pub const Stream = struct {
    a: Allocator,
    /// Made at the first frame.
    dec: ?Dec = null,
    /// The window and the room for the next blocks: a ring at its full size `buf_max`. It grows with the output.
    buf: []u8 = &.{},
    end: usize = 0,
    buf_max: usize = 0,
    /// The frame header (or the 8 bytes of a skippable frame header) so far.
    hdr: [HEAD_MAX]u8 = undefined,
    hdr_len: usize = 0,
    /// The start of a unit that did not fit in a chunk.
    pend: []u8 = &.{},
    pend_len: usize = 0,
    skip_left: usize = 0,
    in_frame: bool = false,
    /// `feed`: decoded bytes not given yet, the last `ready` bytes before `buf[end]`.
    ready: usize = 0,
    /// `feed`: input not read yet, `held[held_pos..held_len]`.
    held_in: []u8 = &.{},
    held_pos: usize = 0,
    held_len: usize = 0,
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
        if (s.dec) |*d| d.deinit();
        if (s.buf.len != 0) a.free(s.buf);
        if (s.pend.len != 0) a.free(s.pend);
        if (s.held_in.len != 0) a.free(s.held_in);
        a.destroy(s);
    }

    /// Bytes held now (the window, the pending block, the input not read yet, the decoder state, the struct).
    pub fn held(s: *const Stream) usize {
        return s.buf.len + s.pend.len + s.held_in.len + @sizeOf(Stream) + if (s.dec != null) @as(usize, @sizeOf(State)) else 0;
    }

    fn fail(s: *Stream, e: Error) Error {
        s.failed = e;
        return e;
    }

    fn startFrame(s: *Stream, hdr: []const u8) Error!void {
        const h = (try parseHead(hdr)) orelse return error.BadFrame;
        if (h.window > s.window_limit) return error.WindowTooLarge;
        if (h.dict) return error.Unsupported;
        const w: usize = @intCast(h.window);
        // The full size: the window and two blocks, as the ring buffer of libzstd (`ZSTD_decodingBufferSize_min`).
        s.buf_max = w + 2 * BLOCK_MAX + 2 * WILDCOPY;
        // A frame from a pipe says 8 MB of window for a small output. So the buffer starts small and
        // grows (`room`) until it has the whole window. The output of the last frame is not history of this one.
        if (s.buf.len < BLOCK_MAX * 2) {
            if (s.buf.len != 0) s.a.free(s.buf);
            s.buf = &.{};
            s.buf = try s.a.alloc(u8, @min(s.buf_max, BLOCK_MAX * 2));
        }
        s.end = 0;
        if (s.dec == null) s.dec = try newDec(s.a);
        try begin(&s.dec.?, s.buf, 0, hdr);
    }

    /// Room for one block after `end`. While the buffer is below its full size, it grows (the history is one piece
    /// then, so it moves with the buffer). At its full size the output goes on at the start of the buffer (a ring,
    /// as in libzstd's `ZSTD_decompressStream`): the decoder sees output that does not follow its last output, and
    /// that last output becomes its older segment (`ext`). The full size keeps the last window of output there.
    fn room(s: *Stream) Error!void {
        if (s.buf.len - s.end >= BLOCK_MAX) return;
        if (s.buf.len < s.buf_max) {
            const old = @intFromPtr(s.buf.ptr);
            s.buf = try s.a.realloc(s.buf, @min(s.buf_max, @max(s.end + BLOCK_MAX, s.buf.len * 2)));
            try rebase(&s.dec.?, old, @intFromPtr(s.buf.ptr));
            if (s.buf.len - s.end >= BLOCK_MAX) return;
        }
        s.end = 0;
    }

    /// Decode one unit. At most `max` bytes in `out`: the rest of the output waits in the buffer (`ready`).
    fn decodeUnit(s: *Stream, unit: []const u8, out: *std.ArrayList(u8), max: usize) Error!void {
        try s.room();
        const n = try feedUnit(&s.dec.?, s.buf, s.end, unit);
        const give = @min(n, max - out.items.len);
        try out.appendSlice(s.a, s.buf[s.end..][0..give]);
        s.ready = n - give;
        s.end += n;
        if (s.dec.?.nextSrcSizeToDecompress() == 0) s.in_frame = false;
    }

    fn pendGrow(s: *Stream, n: usize) Error!void {
        if (s.pend.len >= n) return;
        s.pend = try s.a.realloc(s.pend, @max(n, 64));
    }

    /// Feed `chunk`. The output of the blocks that are whole is appended to `out`. More than `push_limit` bytes of
    /// output is `OutputLimit`. After an error the stream is dead: each call gives the same error.
    pub fn push(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8)) Error!void {
        if (s.failed) |e| return e;
        s.total_in += chunk.len;
        _ = s.feedIn(chunk, out, std.math.maxInt(usize), true) catch |e| return s.fail(e);
    }

    /// Feed `chunk` and give at most `max` bytes of output (at least 1). The stream keeps the input that it did not
    /// read and the output that it did not give. True: it has more output for the input so far, so call `feed` again
    /// (with an empty chunk). False: it needs more input. A chunk given while it is true is kept after the input
    /// that waits (it costs memory). `push_limit` does not apply. A call can give 0 bytes and true (a unit that
    /// writes nothing, as a frame header, then the limit), never false with input that waits.
    pub fn feed(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8), max: usize) Error!bool {
        if (s.failed) |e| return e;
        s.total_in += chunk.len;
        return s.feedIn(chunk, out, out.items.len + @max(max, 1), false) catch |e| return s.fail(e);
    }

    /// `max` is the most that `out` holds after the call.
    fn feedIn(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8), max: usize, limit: bool) Error!bool {
        // First the output that waits, then the input that waits, then `chunk`.
        if (s.ready > 0) {
            const give = @min(s.ready, max -| out.items.len);
            try out.appendSlice(s.a, s.buf[s.end - s.ready ..][0..give]);
            s.ready -= give;
        }
        if (s.ready > 0 or s.held_pos < s.held_len) {
            try s.hold(chunk);
            if (s.ready == 0) {
                s.held_pos += try s.pushIn(s.held_in[s.held_pos..s.held_len], out, max, limit);
                if (s.held_pos == s.held_len) {
                    s.held_pos = 0;
                    s.held_len = 0;
                }
            }
        } else {
            const pos = try s.pushIn(chunk, out, max, limit);
            try s.hold(chunk[pos..]);
        }
        return s.ready > 0 or s.held_pos < s.held_len;
    }

    /// Keep `bytes` after the input that waits.
    fn hold(s: *Stream, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        if (s.held_pos > 0) {
            std.mem.copyForwards(u8, s.held_in[0 .. s.held_len - s.held_pos], s.held_in[s.held_pos..s.held_len]);
            s.held_len -= s.held_pos;
            s.held_pos = 0;
        }
        if (s.held_in.len < s.held_len + bytes.len) s.held_in = try s.a.realloc(s.held_in, s.held_len + bytes.len);
        @memcpy(s.held_in[s.held_len..][0..bytes.len], bytes);
        s.held_len += bytes.len;
    }

    /// Read `chunk` until its end, or until `out` has `max` bytes. Returns the bytes of `chunk` read.
    fn pushIn(s: *Stream, chunk: []const u8, out: *std.ArrayList(u8), max: usize, limit: bool) Error!usize {
        var pos: usize = 0;
        while (out.items.len < max) {
            if (s.skip_left > 0) {
                const n = @min(s.skip_left, chunk.len - pos);
                s.skip_left -= n;
                pos += n;
                if (s.skip_left > 0) break;
                continue;
            }
            if (!s.in_frame) {
                // The header: 4 bytes (the magic), then 8 (a skippable frame), or 5 (the descriptor) and then the
                // size that the descriptor gives.
                var want: usize = 4;
                if (s.hdr_len >= 4) {
                    const magic = std.mem.readInt(u32, s.hdr[0..4], .little);
                    if (skippable(magic)) {
                        want = 8;
                    } else if (magic != MAGIC) {
                        return error.BadFrame;
                    } else {
                        want = HEAD_PREFIX;
                        if (s.hdr_len >= HEAD_PREFIX) want = Z.frameHeaderSize(s.hdr[0..HEAD_PREFIX]) catch return error.BadFrame;
                    }
                }
                if (s.hdr_len < want) {
                    if (pos == chunk.len) break;
                    const n = @min(want - s.hdr_len, chunk.len - pos);
                    @memcpy(s.hdr[s.hdr_len..][0..n], chunk[pos..][0..n]);
                    s.hdr_len += n;
                    pos += n;
                    continue;
                }
                // `want` is final here: 8 for a skippable frame, else the size of the whole header (6 or more).
                const hdr = s.hdr[0..s.hdr_len];
                s.hdr_len = 0;
                if (want == 8 and skippable(std.mem.readInt(u32, hdr[0..4], .little))) {
                    s.skip_left = std.mem.readInt(u32, hdr[4..8], .little);
                    continue;
                }
                try s.startFrame(hdr);
                s.in_frame = true;
                continue;
            }
            const need = s.dec.?.nextSrcSizeToDecompress();
            if (s.pend_len > 0 or chunk.len - pos < need) {
                if (pos == chunk.len) break;
                try s.pendGrow(need);
                const n = @min(need - s.pend_len, chunk.len - pos);
                @memcpy(s.pend[s.pend_len..][0..n], chunk[pos..][0..n]);
                s.pend_len += n;
                pos += n;
                if (s.pend_len < need) break;
                s.pend_len = 0;
                try s.decodeUnit(s.pend[0..need], out, max);
            } else {
                try s.decodeUnit(chunk[pos..][0..need], out, max);
                pos += need;
            }
            if (limit) {
                if (out.items.len > s.push_limit) return error.OutputLimit;
            }
        }
        return pos;
    }

    /// The end of the input: it must be at the end of a frame, with all output given (`feed`).
    pub fn finish(s: *Stream) Error!void {
        if (s.failed) |e| return e;
        if (s.total_in == 0 or s.in_frame or s.hdr_len != 0 or s.pend_len != 0 or s.skip_left != 0) return error.Truncated;
        if (s.ready != 0 or s.held_pos < s.held_len) return error.Truncated;
    }
};
