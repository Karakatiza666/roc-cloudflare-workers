//! Corrupt-input check of the new hostlib/native/zstd.zig against the old one (std.compress.zstd, variants/std).
//! Damaged copies of real frames go through `decode` and through a `Stream` with random chunks, in both.
//! The run is ReleaseSafe (bounds checks on in all code) with a leak-checking allocator: a trap or a leak stops it.
//! It counts how the two answers compare: same bytes, same error tag, or a difference (by kind).
//! Usage: tagfuzz <iterations> <seed> <file.zst>...
const std = @import("std");
const new = @import("new");
const old = @import("old");

fn tag(comptime M: type, r: M.Error![]u8) []const u8 {
    return if (r) |_| "ok" else |e| M.code(e);
}

fn runStream(comptime M: type, a: std.mem.Allocator, in: []const u8, chunk: usize) M.Error![]u8 {
    const s = try M.Stream.open(a, M.WINDOW_DEFAULT, 64 << 20);
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    while (pos < in.len) {
        const n = @min(chunk, in.len - pos);
        try s.push(in[pos..][0..n], &out);
        pos += n;
    }
    try s.finish();
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

/// `feed` of the new stream in random chunks and parts (more is drained before the next chunk).
fn runFeed(a: std.mem.Allocator, in: []const u8, chunk: usize, max: usize) new.Error![]u8 {
    const s = try new.Stream.open(a, new.WINDOW_DEFAULT, 64 << 20);
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var more = false;
    while (pos < in.len or more) {
        const n = if (more) 0 else @min(chunk, in.len - pos);
        const before = out.items.len;
        more = try s.feed(in[pos..][0..n], &out, max);
        if (out.items.len - before > max) @panic("a part over max");
        pos += n;
    }
    try s.finish();
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

pub fn main(init: std.process.Init) !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer if (dbg.deinit() == .leak) @panic("leak");
    const a = dbg.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iters = try std.fmt.parseInt(usize, args[1], 10);
    const seed = try std.fmt.parseInt(u64, args[2], 10);
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| a.free(f);
        files.deinit(a);
    }
    for (args[3..]) |p| try files.append(a, try std.Io.Dir.cwd().readFileAlloc(init.io, p, a, .unlimited));
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer {
        for (counts.keys()) |k| a.free(k);
        counts.deinit(a);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var show: usize = 4;
    for (0..iters) |_| {
        const fi = r.uintLessThan(usize, files.items.len);
        const f = files.items[fi];
        buf.clearRetainingCapacity();
        try buf.appendSlice(a, f);
        const mut = r.uintLessThan(u8, 5);
        switch (mut) {
            0 => for (0..1 + r.uintLessThan(usize, 8)) |_| {
                buf.items[r.uintLessThan(usize, buf.items.len)] = r.int(u8);
            },
            1 => for (0..1 + r.uintLessThan(usize, 4)) |_| {
                const i = r.uintLessThan(usize, @min(buf.items.len, 512));
                buf.items[i] ^= @as(u8, 1) << r.int(u3);
            },
            2 => buf.items.len = r.uintLessThan(usize, buf.items.len),
            3 => { // bytes after the frame
                for (0..1 + r.uintLessThan(usize, 12)) |_| try buf.append(a, r.int(u8));
            },
            else => {
                const n = 1 + r.uintLessThan(usize, 64);
                if (buf.items.len > n * 2) {
                    const s = r.uintLessThan(usize, buf.items.len - n);
                    const t = r.uintLessThan(usize, buf.items.len - n);
                    std.mem.copyForwards(u8, buf.items[t..][0..n], buf.items[s..][0..n]);
                }
            },
        }
        const in = buf.items;
        const chunk = 1 + r.uintLessThan(usize, 70000);
        {
            // feed against the stream of the same code: the same answer.
            const rf = runFeed(a, in, chunk, 1 + r.uintLessThan(usize, 300000));
            defer if (rf) |b| a.free(b) else |_| {};
            const rs = runStream(new, a, in, chunk);
            defer if (rs) |b| a.free(b) else |_| {};
            const same = if (rf) |bf| (if (rs) |bs| std.mem.eql(u8, bf, bs) else |_| false) else |ef| (if (rs) |_| false else |es| ef == es);
            const k = try a.dupe(u8, if (same) "feed: same as stream" else "feed: OTHER than stream");
            const g = try counts.getOrPut(a, k);
            if (g.found_existing) a.free(k) else g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        inline for (.{ "decode", "stream" }) |kind| {
            const rn = if (comptime std.mem.eql(u8, kind, "decode")) new.decode(a, in, 8 << 20) else runStream(new, a, in, chunk);
            const ro = if (comptime std.mem.eql(u8, kind, "decode")) old.decode(a, in, 8 << 20) else runStream(old, a, in, chunk);
            defer if (rn) |b| a.free(b) else |_| {};
            defer if (ro) |b| a.free(b) else |_| {};
            const tn = tag(new, rn);
            const to = tag(old, ro);
            var key_buf: [96]u8 = undefined;
            const key = if (std.mem.eql(u8, tn, to))
                (if (rn) |bn| (if (std.mem.eql(u8, bn, ro catch unreachable)) "same bytes" else "both ok, other bytes") else |_| "same error tag")
            else
                try std.fmt.bufPrint(&key_buf, "old {s}, new {s}", .{ to, tn });
            const full = try std.fmt.allocPrint(a, "{s}: {s}", .{ kind, key });
            if (std.mem.eql(u8, to, "bad_frame") and std.mem.eql(u8, tn, "ok") and show > 0) {
                show -= 1;
                std.debug.print("example: {s} file {s} mutation {d}, len {d}\n", .{ kind, args[3 + fi], mut, in.len });
                if (show == 0) try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zstd-speed/out/example.zst", .data = in });
            }
            const gop = try counts.getOrPut(a, full);
            if (gop.found_existing) a.free(full) else gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    std.debug.print("iterations {d} (each: decode and stream)\n", .{iters});
    for (counts.keys(), counts.values()) |k, v| std.debug.print("{d:>8}  {s}\n", .{ v, k });
}
