//! Tests of the Native ops (PLAN.md 8e). Run from the repo root: `zig test hostlib/native/native_test.zig`.
//! The data is in research/native/data (make it with research/native/make-data.sh). The expected bytes
//! come from the `zstd` CLI, and the hash digests from `sha256sum` and the Python `blake3` package.

const std = @import("std");
const native = @import("native.zig");
const zstd = @import("zstd.zig");
const Op = native.Op;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

// ---------------------------------------------------------------- helpers

fn readData(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "research/native/data/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
}

/// An allocator that counts the live bytes and the peak (the memory of the task).
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn add(c: *Counting, n: usize) void {
        c.live += n;
        c.peak = @max(c.peak, c.live);
    }
    fn alloc(p: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        const r = c.child.rawAlloc(len, al, ra) orelse return null;
        c.add(len);
        return r;
    }
    fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(p));
        if (!c.child.rawResize(m, al, n, ra)) return false;
        c.live -= m.len;
        c.add(n);
        return true;
    }
    fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        // A move holds the old and the new block at the same time.
        const r = c.child.rawRemap(m, al, n, ra) orelse return null;
        c.live -= m.len;
        c.add(n);
        return r;
    }
    fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(p));
        c.live -= m.len;
        c.child.rawFree(m, al, ra);
    }
};

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

/// `call` with the result copied out and released, so a test sees plain bytes.
fn callOwned(a: std.mem.Allocator, owner: usize, op: Op, in: []const u8) !struct { status: u8, bytes: []u8 } {
    const r = native.call(a, owner, @backingInt(op), in);
    defer r.release(a);
    return .{ .status = r.status, .bytes = try a.dupe(u8, r.bytes) };
}

fn handleOf(r: anytype) u32 {
    return std.mem.readInt(u32, r.bytes[0..4], .little);
}

/// Open a zstd stream, push `data` in `chunk` sized pieces, close. The output of all pushes.
fn streamAll(a: std.mem.Allocator, owner: usize, data: []const u8, chunk: usize, open_args: []const u8) ![]u8 {
    const op = try callOwned(a, owner, .zstd_stream_open, open_args);
    defer a.free(op.bytes);
    try expectEqual(@as(u8, 0), op.status);
    const h = handleOf(op);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    while (pos < data.len) {
        const n = @min(chunk, data.len - pos);
        const in = try std.mem.concat(a, u8, &.{ &le32(h), data[pos..][0..n] });
        defer a.free(in);
        const r = try callOwned(a, owner, .zstd_stream_push, in);
        defer a.free(r.bytes);
        if (r.status != 0) {
            const cl = try callOwned(a, owner, .zstd_stream_close, &le32(h));
            a.free(cl.bytes);
            return error.StreamFailed;
        }
        try out.appendSlice(a, r.bytes);
        pos += n;
    }
    const c = try callOwned(a, owner, .zstd_stream_close, &le32(h));
    defer a.free(c.bytes);
    if (c.status != 0) return error.StreamFailed;
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------- zstd: one frame

// R-Z1: a package .tar.zst decodes to the bytes of `zstd -d`
test "zstd_decode: the bytes equal zstd -d" {
    const want = try readData(gpa, "pkg.tar");
    defer gpa.free(want);
    // file input (content size, checksum), pipe (no size, 8 MB window), no checksum, 16 MB window.
    for ([_][]const u8{ "pkg.tar.zst", "pkg-pipe.tar.zst", "pkg-nocheck.tar.zst", "pkg-w24.tar.zst" }) |name| {
        const z = try readData(gpa, name);
        defer gpa.free(z);
        const got = try zstd.decode(gpa, z, 1 << 20);
        defer gpa.free(got);
        try expectEqualSlices(u8, want, got);
    }
}

fn sha256Hex(b: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

// R-Z1: a real package made by `roc bundle` (roc-parser: window 2 MiB, no content size, no checksum), in one
// piece and in chunks of 1, 7, 4096 and 65536. The reference is `zstd -d`.
test "zstd: a package made by roc bundle" {
    const z = try readData(gpa, "roc-parser.tar.zst");
    defer gpa.free(z);
    const sum = try readData(gpa, "roc-parser.sha256");
    defer gpa.free(sum);
    const want = std.mem.trim(u8, sum, "\n");
    const got = try zstd.decode(gpa, z, 1 << 22);
    defer gpa.free(got);
    try expectEqual(@as(usize, 511488), got.len);
    try expectEqualSlices(u8, want, &sha256Hex(got));
    for ([_]usize{ 1, 7, 4096, 65536 }) |chunk| {
        const g = try streamAll(gpa, 1, z, chunk, "");
        defer gpa.free(g);
        try expectEqualSlices(u8, want, &sha256Hex(g));
    }
}

// R-Z2: two frames and a skippable frame between them
test "zstd_decode: many frames, a skippable frame" {
    const want = try readData(gpa, "multi.tar");
    defer gpa.free(want);
    const z = try readData(gpa, "multi.zst");
    defer gpa.free(z);
    const got = try zstd.decode(gpa, z, want.len);
    defer gpa.free(got);
    try expectEqualSlices(u8, want, got);
}

// R-Z3: the output limit. Exactly the size is ok. One byte less stops with an error, and no output.
test "zstd_decode: the limit is exact" {
    const want = try readData(gpa, "pkg.tar");
    defer gpa.free(want);
    for ([_][]const u8{ "pkg.tar.zst", "pkg-pipe.tar.zst" }) |name| {
        const z = try readData(gpa, name);
        defer gpa.free(z);
        const ok = try zstd.decode(gpa, z, want.len);
        gpa.free(ok);
        try expectError(error.OutputLimit, zstd.decode(gpa, z, want.len - 1));
        try expectError(error.OutputLimit, zstd.decode(gpa, z, 0));
    }
}

// R-Z4: a small archive (150 bytes) that decodes to 4 MB stops at the limit, and the memory stays near
// the limit. With a content size in the header (zeros.zst) it stops before the first block.
// Without it (zeros-pipe.zst, an 8 MB window) it stops after the block that crosses the limit.
test "zstd_decode: a bomb stops at the limit, memory stays near it" {
    const limit = 256 << 10;
    for ([_][]const u8{ "zeros.zst", "zeros-pipe.zst" }) |name| {
        const z = try readData(gpa, name);
        defer gpa.free(z);
        const full = try zstd.decode(gpa, z, 4 << 20); // the size is ok
        defer gpa.free(full);
        try expectEqual(@as(usize, 4 << 20), full.len);
        var c: Counting = .{ .child = gpa };
        try expectError(error.OutputLimit, zstd.decode(c.allocator(), z, limit));
        try expectEqual(@as(usize, 0), c.live); // nothing leaks on the error
        // The buffer is the output: at most the limit plus one block, and a growth step moves it once.
        try std.testing.expect(c.peak <= 2 * (limit + zstd.BLOCK_MAX));
    }
}

test "zstd_decode: the 4 MB output of the bomb is right" {
    const z = try readData(gpa, "zeros.zst");
    defer gpa.free(z);
    const sum = try readData(gpa, "zeros.sha256");
    defer gpa.free(sum);
    const got = try zstd.decode(gpa, z, 4 << 20);
    defer gpa.free(got);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got, &h, .{});
    try expectEqualSlices(u8, std.mem.trim(u8, sum, "\n"), &std.fmt.bytesToHex(h, .lower));
}

// R-Z5: the window costs no memory in the one-shot decode (a frame from a pipe says 8 MB or 16 MB)
test "zstd_decode: the window of the frame is not allocated" {
    for ([_][]const u8{ "pkg-pipe.tar.zst", "pkg-w24.tar.zst" }) |name| {
        const z = try readData(gpa, name);
        defer gpa.free(z);
        var c: Counting = .{ .child = gpa };
        const got = try zstd.decode(c.allocator(), z, 1 << 20);
        gpa.free(got);
        try std.testing.expect(c.peak < 512 << 10);
    }
}

// R-Z6: a bad frame is an error, and a cut frame is "truncated"
test "zstd_decode: bad and cut input" {
    const z = try readData(gpa, "pkg.tar.zst");
    defer gpa.free(z);
    try expectError(error.Truncated, zstd.decode(gpa, "", 1 << 20));
    try expectError(error.Truncated, zstd.decode(gpa, z[0..2], 1 << 20));
    try expectError(error.BadFrame, zstd.decode(gpa, "not a frame at all", 1 << 20));
    try expectError(error.Truncated, zstd.decode(gpa, z[0 .. z.len / 2], 1 << 20));
    try expectError(error.Truncated, zstd.decode(gpa, z[0 .. z.len - 5], 1 << 20));
    // Bytes after the frame are not a frame.
    const tail = try std.mem.concat(gpa, u8, &.{ z, "xyz1234" });
    defer gpa.free(tail);
    try expectError(error.BadFrame, zstd.decode(gpa, tail, 1 << 20));
}

// R-Z7: cuts and flipped bits give an error or bytes, never a trap (the safety checks of Debug are on)
test "zstd_decode: damaged input does not trap" {
    const z = try readData(gpa, "pkg-pipe.tar.zst");
    defer gpa.free(z);
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    const bad = try gpa.dupe(u8, z);
    defer gpa.free(bad);
    for (0..300) |_| {
        @memcpy(bad, z);
        for (0..1 + rnd.uintLessThan(usize, 3)) |_| bad[rnd.uintLessThan(usize, bad.len)] ^= @as(u8, 1) << rnd.int(u3);
        const cut = bad[0 .. 1 + rnd.uintLessThan(usize, bad.len)];
        if (zstd.decode(gpa, cut, 1 << 20)) |o| gpa.free(o) else |_| {}
    }
}

// ---------------------------------------------------------------- zstd: stream

// R-Z8: the stream gives the same bytes for chunks of 1, 7, 4096 and 64 KB
test "zstd stream: chunk sizes 1, 7, 4096 and 65536 give the same bytes" {
    const want = try readData(gpa, "pkg.tar");
    defer gpa.free(want);
    for ([_][]const u8{ "pkg.tar.zst", "pkg-pipe.tar.zst", "pkg-nocheck.tar.zst" }) |name| {
        const z = try readData(gpa, name);
        defer gpa.free(z);
        for ([_]usize{ 1, 7, 4096, 65536 }) |chunk| {
            const got = try streamAll(gpa, 1, z, chunk, "");
            defer gpa.free(got);
            try expectEqualSlices(u8, want, got);
        }
    }
    // Frames and a skippable frame cut at any place.
    const mt = try readData(gpa, "multi.tar");
    defer gpa.free(mt);
    const mz = try readData(gpa, "multi.zst");
    defer gpa.free(mz);
    for ([_]usize{ 1, 7, 4096, 65536 }) |chunk| {
        const got = try streamAll(gpa, 1, mz, chunk, "");
        defer gpa.free(got);
        try expectEqualSlices(u8, mt, got);
    }
}

// R-Z9: a stream with a window that the output passes many times (the window moves down in its buffer)
test "zstd stream: a 10 MB archive, window 8 MB, output 33 MB" {
    const z = try readData(gpa, "big-10m.tar.zst");
    defer gpa.free(z);
    const sum = try readData(gpa, "big-10m.sha256");
    defer gpa.free(sum);
    for ([_]usize{ 4096, 65536, 1 << 20 }) |chunk| {
        var c: Counting = .{ .child = gpa };
        const got = try streamAll(c.allocator(), 1, z, chunk, "");
        defer c.allocator().free(got);
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(got, &h, .{});
        try expectEqualSlices(u8, std.mem.trim(u8, sum, "\n"), &std.fmt.bytesToHex(h, .lower));
    }
}

// R-Z10: the window limit. A frame over it is refused, whatever the chunk.
test "zstd stream: the window limit" {
    const z = try readData(gpa, "pkg-w24.tar.zst");
    defer gpa.free(z);
    // default 8 MB: the 16 MB window of this frame is too large
    try expectError(error.StreamFailed, streamAll(gpa, 1, z, 4096, ""));
    // a limit above WINDOW_MAX (8 MB) is refused at open
    const big = try callOwned(gpa, 1, .zstd_stream_open, &le32(16 << 20));
    defer gpa.free(big.bytes);
    try expectEqual(@as(u8, 1), big.status);
    try expectEqualSlices(u8, "bad_argument", big.bytes);
    // a frame of 8 MB (from a pipe) is in the limit: ok
    const zp = try readData(gpa, "pkg-pipe.tar.zst");
    defer gpa.free(zp);
    const want = try readData(gpa, "pkg.tar");
    defer gpa.free(want);
    const got = try streamAll(gpa, 1, zp, 4096, "");
    defer gpa.free(got);
    try expectEqualSlices(u8, want, got);
    // The error code is "window_too_large"
    const op = try callOwned(gpa, 1, .zstd_stream_open, &le32(1 << 20));
    defer gpa.free(op.bytes);
    const in = try std.mem.concat(gpa, u8, &.{ &le32(handleOf(op)), z });
    defer gpa.free(in);
    const r = try callOwned(gpa, 1, .zstd_stream_push, in);
    defer gpa.free(r.bytes);
    try expectEqual(@as(u8, 1), r.status);
    try expectEqualSlices(u8, "window_too_large", r.bytes);
    // A limit over the hard limit is a bad argument.
    const o2 = try callOwned(gpa, 1, .zstd_stream_open, &le32(zstd.WINDOW_MAX + 1));
    defer gpa.free(o2.bytes);
    try expectEqual(@as(u8, 1), o2.status);
    try expectEqualSlices(u8, "bad_argument", o2.bytes);
    native.endTask(gpa, 1, .free);
}

// R-Z11: memory of a stream: the buffer grows with the output, it does not start at the 8 MB window
test "zstd stream: a small output from an 8 MB window frame is small in memory" {
    const z = try readData(gpa, "pkg-pipe.tar.zst");
    defer gpa.free(z);
    var c: Counting = .{ .child = gpa };
    const got = try streamAll(c.allocator(), 1, z, 4096, "");
    c.allocator().free(got);
    try std.testing.expect(c.peak < 1 << 20);
}

// R-Z12: a push gives at most the push limit (one block over), and a stream that failed stays failed
test "zstd stream: the output limit of a push" {
    const z = try readData(gpa, "zeros-pipe.zst");
    defer gpa.free(z);
    var c: Counting = .{ .child = gpa };
    const a = c.allocator();
    {
        const op = try callOwned(a, 1, .zstd_stream_open, &(le32(0) ++ le32(256 << 10)));
        defer a.free(op.bytes);
        const h = handleOf(op);
        const in = try std.mem.concat(a, u8, &.{ &le32(h), z });
        defer a.free(in);
        const r = try callOwned(a, 1, .zstd_stream_push, in);
        defer a.free(r.bytes);
        try expectEqual(@as(u8, 1), r.status);
        try expectEqualSlices(u8, "output_limit", r.bytes);
        // dead: the same error again
        const r2 = try callOwned(a, 1, .zstd_stream_push, in);
        defer a.free(r2.bytes);
        try expectEqualSlices(u8, "output_limit", r2.bytes);
        const cl = try callOwned(a, 1, .zstd_stream_close, &le32(h));
        defer a.free(cl.bytes);
        try expectEqual(@as(u8, 1), cl.status);
    }
    // The output is 4 MB. The stream stopped near 256 KB: the buffer and the output list are small.
    try std.testing.expect(c.peak <= 1536 << 10);
    try expectEqual(@as(usize, 0), c.live);
}

// R-Z13: close in the middle of a frame is an error; bad bytes are an error
test "zstd stream: cut and bad input" {
    const z = try readData(gpa, "pkg.tar.zst");
    defer gpa.free(z);
    try expectError(error.StreamFailed, streamAll(gpa, 1, z[0 .. z.len - 1], 100, ""));
    try expectError(error.StreamFailed, streamAll(gpa, 1, z[0..10], 3, ""));
    try expectError(error.StreamFailed, streamAll(gpa, 1, "garbage garbage", 4, ""));
    try expectError(error.StreamFailed, streamAll(gpa, 1, "", 4, "")); // nothing is not a frame
}

// R-Z14: damaged input in chunks does not trap
test "zstd stream: damaged input does not trap" {
    const z = try readData(gpa, "pkg-pipe.tar.zst");
    defer gpa.free(z);
    var prng = std.Random.DefaultPrng.init(0xBAD);
    const rnd = prng.random();
    const bad = try gpa.dupe(u8, z);
    defer gpa.free(bad);
    for (0..100) |_| {
        @memcpy(bad, z);
        for (0..1 + rnd.uintLessThan(usize, 3)) |_| bad[rnd.uintLessThan(usize, bad.len)] ^= @as(u8, 1) << rnd.int(u3);
        if (streamAll(gpa, 1, bad, 1 + rnd.uintLessThan(usize, 5000), "")) |o| gpa.free(o) else |_| {}
        native.endTask(gpa, 1, .free);
    }
}

// ---------------------------------------------------------------- hashes

const Expect = struct { name: []const u8, b3: []const u8, sha: []const u8 };

fn hashChunks(a: std.mem.Allocator, owner: usize, comptime which: enum { blake3, sha256 }, data: []const u8, chunk: usize) ![]u8 {
    const new_op: Op = if (which == .blake3) .blake3_new else .sha256_new;
    const upd: Op = if (which == .blake3) .blake3_update else .sha256_update;
    const fin: Op = if (which == .blake3) .blake3_final else .sha256_final;
    const n = try callOwned(a, owner, new_op, "");
    defer a.free(n.bytes);
    try expectEqual(@as(u8, 0), n.status);
    const h = handleOf(n);
    var pos: usize = 0;
    while (pos < data.len) {
        const m = @min(chunk, data.len - pos);
        const in = try std.mem.concat(a, u8, &.{ &le32(h), data[pos..][0..m] });
        defer a.free(in);
        const u = try callOwned(a, owner, upd, in);
        defer a.free(u.bytes);
        try expectEqual(@as(u8, 0), u.status);
        try expectEqual(@as(usize, 0), u.bytes.len);
        pos += m;
    }
    const f = try callOwned(a, owner, fin, &le32(h));
    try expectEqual(@as(u8, 0), f.status);
    return f.bytes;
}

// R-H1, R-H2: BLAKE3 and SHA-256 of a file, in chunks of 64 KB (and of 1 byte, 1000 bytes), equal b3sum / sha256sum
test "blake3 and sha256: chunked digests equal the references" {
    const list = try readData(gpa, "hashes.txt");
    defer gpa.free(list);
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const name = f.next().?;
        const b3 = f.next().?;
        const sha = f.next().?;
        const data = try readData(gpa, name);
        defer gpa.free(data);
        for ([_]usize{ 65536, 1000, 1, 1 << 30 }) |chunk| {
            if (chunk == 1 and data.len > 1000) continue; // 1 byte chunks: only for the small file
            const b = try hashChunks(gpa, 1, .blake3, data, chunk);
            defer gpa.free(b);
            try expectEqualSlices(u8, b3, &std.fmt.bytesToHex(b[0..32].*, .lower));
            const s = try hashChunks(gpa, 1, .sha256, data, chunk);
            defer gpa.free(s);
            try expectEqualSlices(u8, sha, &std.fmt.bytesToHex(s[0..32].*, .lower));
        }
        seen += 1;
    }
    try expectEqual(@as(usize, 4), seen);
    try expectEqual(@as(usize, 0), native.inUse(null)); // `final` frees the handle
}

// A digest of the empty input is the known vector of the BLAKE3 spec.
test "blake3: the empty input" {
    const b = try hashChunks(gpa, 1, .blake3, "", 1);
    defer gpa.free(b);
    try expectEqualSlices(u8, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", &std.fmt.bytesToHex(b[0..32].*, .lower));
}

// ---------------------------------------------------------------- handles

// R-N1: a handle of another task gives status 1
test "handles: a handle of another task is status 1" {
    const n = try callOwned(gpa, 7, .blake3_new, "");
    defer gpa.free(n.bytes);
    const h = handleOf(n);
    const in = try std.mem.concat(gpa, u8, &.{ &le32(h), "data" });
    defer gpa.free(in);
    // task 8 uses the handle of task 7: update, final, and also a zstd call on a zstd handle
    for ([_]Op{ .blake3_update, .blake3_final }) |op| {
        const r = try callOwned(gpa, 8, op, in);
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 1), r.status);
        try expectEqualSlices(u8, "wrong_task", r.bytes);
    }
    const zo = try callOwned(gpa, 7, .zstd_stream_open, "");
    defer gpa.free(zo.bytes);
    for ([_]Op{ .zstd_stream_push, .zstd_stream_close }) |op| {
        const zin = try std.mem.concat(gpa, u8, &.{ &le32(handleOf(zo)), "x" });
        defer gpa.free(zin);
        const r = try callOwned(gpa, 8, op, zin);
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 1), r.status);
        try expectEqualSlices(u8, "wrong_task", r.bytes);
    }
    // the owner still has it, and nothing of task 8 changed it
    const ok = try callOwned(gpa, 7, .blake3_update, in);
    defer gpa.free(ok.bytes);
    try expectEqual(@as(u8, 0), ok.status);
    native.endTask(gpa, 7, .free);
}

// R-N2: a closed handle, a handle of another kind, a wild number, and a slot that was used again
test "handles: closed, wrong kind, wild, reused" {
    const n = try callOwned(gpa, 1, .sha256_new, "");
    defer gpa.free(n.bytes);
    const h = handleOf(n);
    const wrong = try callOwned(gpa, 1, .blake3_update, &le32(h));
    defer gpa.free(wrong.bytes);
    try expectEqualSlices(u8, "wrong_kind", wrong.bytes);
    const f = try callOwned(gpa, 1, .sha256_final, &le32(h));
    gpa.free(f.bytes);
    // closed
    const again = try callOwned(gpa, 1, .sha256_final, &le32(h));
    defer gpa.free(again.bytes);
    try expectEqual(@as(u8, 1), again.status);
    try expectEqualSlices(u8, "bad_handle", again.bytes);
    // the next handle uses the same slot with another generation: the old number stays bad
    const n2 = try callOwned(gpa, 1, .sha256_new, "");
    defer gpa.free(n2.bytes);
    try std.testing.expect(handleOf(n2) != h);
    const old = try callOwned(gpa, 1, .sha256_update, &le32(h));
    defer gpa.free(old.bytes);
    try expectEqualSlices(u8, "bad_handle", old.bytes);
    for ([_]u32{ 0, 1000, 0xFFFFFFFF, 0x100 }) |w| {
        const r = try callOwned(gpa, 1, .blake3_final, &le32(w));
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 1), r.status);
    }
    native.endTask(gpa, 1, .free);
}

// R-N3: endTask drops all handles of the task (and frees their memory with mode .free). The leak check of
// std.testing.allocator fails the test when a block stays.
test "handles: endTask frees the handles of the task, not of others" {
    const z = try readData(gpa, "pkg.tar.zst");
    defer gpa.free(z);
    var handles: [3]u32 = undefined;
    const ops = [_]Op{ .zstd_stream_open, .blake3_new, .sha256_new };
    for (ops, 0..) |op, i| {
        const r = try callOwned(gpa, 5, op, "");
        defer gpa.free(r.bytes);
        handles[i] = handleOf(r);
    }
    // a stream with a window in memory
    const in = try std.mem.concat(gpa, u8, &.{ &le32(handles[0]), z[0..20000] });
    defer gpa.free(in);
    const p = try callOwned(gpa, 5, .zstd_stream_push, in);
    gpa.free(p.bytes);
    const other = try callOwned(gpa, 6, .blake3_new, "");
    defer gpa.free(other.bytes);
    try expectEqual(@as(usize, 4), native.inUse(null));
    native.endTask(gpa, 5, .free);
    try expectEqual(@as(usize, 1), native.inUse(null));
    try expectEqual(@as(usize, 0), native.inUse(5));
    for (handles, [_]Op{ .zstd_stream_close, .blake3_final, .sha256_final }) |h, op| {
        const r = try callOwned(gpa, 5, op, &le32(h));
        defer gpa.free(r.bytes);
        try expectEqualSlices(u8, "bad_handle", r.bytes);
    }
    native.endTask(gpa, 6, .free);
    try expectEqual(@as(usize, 0), native.inUse(null));
}

// R-N4: the limits of a task
test "handles: a task has at most 16 handles and 4 streams" {
    var hs: [native.MAX_PER_TASK]u32 = undefined;
    for (&hs) |*h| {
        const r = try callOwned(gpa, 9, .sha256_new, "");
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 0), r.status);
        h.* = handleOf(r);
    }
    const over = try callOwned(gpa, 9, .sha256_new, "");
    defer gpa.free(over.bytes);
    try expectEqualSlices(u8, "too_many_handles", over.bytes);
    // another task is not stopped by it
    const o = try callOwned(gpa, 10, .sha256_new, "");
    defer gpa.free(o.bytes);
    try expectEqual(@as(u8, 0), o.status);
    native.endTask(gpa, 9, .free);
    native.endTask(gpa, 10, .free);
    for (0..native.MAX_STREAMS_PER_TASK) |_| {
        const r = try callOwned(gpa, 9, .zstd_stream_open, "");
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 0), r.status);
    }
    const sx = try callOwned(gpa, 9, .zstd_stream_open, "");
    defer gpa.free(sx.bytes);
    try expectEqualSlices(u8, "too_many_handles", sx.bytes);
    native.endTask(gpa, 9, .free);
}

// R-N6: no task (owner 0, the host) can hold a handle: `endTask` would never free it
test "handles: owner 0 gets no handle" {
    for ([_]Op{ .blake3_new, .sha256_new, .zstd_stream_open }) |op| {
        const r = try callOwned(gpa, 0, op, "");
        defer gpa.free(r.bytes);
        try expectEqual(@as(u8, 1), r.status);
        try expectEqualSlices(u8, "no_task", r.bytes);
    }
    try expectEqual(@as(usize, 0), native.inUse(null));
}

test "ops: unknown op and short arguments are status 1" {
    const r = native.call(gpa, 1, 99, "");
    try expectEqual(@as(u8, 1), r.status);
    for ([_]Op{ .zstd_decode, .zstd_stream_push, .zstd_stream_close, .blake3_update, .blake3_final, .sha256_update, .sha256_final }) |op| {
        const s = native.call(gpa, 1, @backingInt(op), "ab");
        try expectEqual(@as(u8, 1), s.status);
    }
}

// R-N5: out of memory is status 4 (the bridge makes a clean trap), and nothing leaks
test "ops: out of memory is status 4, with no leak" {
    const z = try readData(gpa, "pkg.tar.zst");
    defer gpa.free(z);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        const in = try std.mem.concat(gpa, u8, &.{ &le32(1 << 20), z });
        defer gpa.free(in);
        const r = native.call(fa.allocator(), 1, @backingInt(Op.zstd_decode), in);
        defer r.release(fa.allocator());
        if (r.status == 0) break;
        try expectEqual(@as(u8, 4), r.status);
    }
    // Each op that makes a handle, with a failed allocation at each step: status 4, and no slot is left
    // that points at freed memory.
    for ([_]Op{ .zstd_stream_open, .blake3_new, .sha256_new }) |op| {
        for (0..6) |k| {
            var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = k });
            const a = fa.allocator();
            const n = native.call(a, 2, @backingInt(op), "");
            defer n.release(a);
            if (n.status == 0) {
                try expectEqual(@as(usize, 1), native.inUse(null));
            } else {
                try expectEqual(@as(u8, 4), n.status);
                try expectEqual(@as(usize, 0), native.inUse(null));
            }
            native.endTask(a, 2, .free);
        }
    }
}
