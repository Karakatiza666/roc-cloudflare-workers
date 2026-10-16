const std = @import("std");
const zstd = @import("zstd");
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const z = try std.Io.Dir.cwd().readFileAlloc(io, "research/native/data/big-10m.tar.zst", a, .limited(100 << 20));
    var best: u64 = std.math.maxInt(u64);
    var n: usize = 0;
    for (0..3) |_| {
        const t0 = std.Io.Clock.awake.now(io);
        const o = try zstd.decode(a, z, 100 << 20);
        const t1 = std.Io.Clock.awake.now(io);
        n = o.len;
        a.free(o);
        best = @min(best, @as(u64, @intCast(t0.durationTo(t1).toNanoseconds())));
    }
    std.debug.print("native std zstd one-shot: {} bytes in {d:.1} ms = {d:.0} MB/s\n", .{ n, @as(f64, @floatFromInt(best)) / 1e6, @as(f64, @floatFromInt(n)) / 1e6 / (@as(f64, @floatFromInt(best)) / 1e9) });
}
