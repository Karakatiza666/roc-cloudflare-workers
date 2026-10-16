//! Damaged input: random bit flips and cuts of real archives, through decode and the stream. A panic (safety
//! check of ReleaseSafe) or a leak is a finding. Run: see README ("Fuzz").
const std = @import("std");
const zstd = @import("zstd");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iters: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 20000;
    var ok: usize = 0;
    var err: usize = 0;
    for ([_][]const u8{ "pkg.tar.zst", "pkg-pipe.tar.zst", "multi.zst", "zeros-pipe.zst" }) |name| {
        var path: [128]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "research/native/data/{s}", .{name});
        const z = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 24));
        defer gpa.free(z);
        var prng = std.Random.DefaultPrng.init(0xF022 + z.len);
        const rnd = prng.random();
        const bad = try gpa.dupe(u8, z);
        defer gpa.free(bad);
        for (0..iters) |i| {
            @memcpy(bad, z);
            const flips = 1 + rnd.uintLessThan(usize, 4);
            for (0..flips) |_| {
                // half of the flips go to the first 64 bytes (headers)
                const at = if (rnd.boolean()) rnd.uintLessThan(usize, @min(64, bad.len)) else rnd.uintLessThan(usize, bad.len);
                bad[at] ^= @as(u8, 1) << rnd.int(u3);
            }
            const cut = if (i % 4 == 0) bad[0 .. 1 + rnd.uintLessThan(usize, bad.len)] else bad;
            if (zstd.decode(gpa, cut, 1 << 22)) |o| {
                gpa.free(o);
                ok += 1;
            } else |_| err += 1;
            // the stream, chunks of 1..3000
            var s = try zstd.Stream.open(gpa, 8 << 20, 1 << 22);
            defer s.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var pos: usize = 0;
            const ch = 1 + rnd.uintLessThan(usize, 3000);
            while (pos < cut.len) : (pos += ch) {
                s.push(cut[pos..@min(pos + ch, cut.len)], &out) catch break;
                if (out.items.len > (1 << 22)) break;
            }
        }
    }
    std.debug.print("fuzz: {} decodes ok, {} errors, no panic\n", .{ ok, err });
}
