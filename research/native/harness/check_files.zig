//! Decode each file of the arguments with `decode` and with the stream (1000 byte chunks). Print
//! "<sha256 of the output> <size> <file>" for the one-shot, and MISMATCH when the stream differs.
//! Compare with: zstd -d -c FILE | sha256sum
const std = @import("std");
const zstd = @import("zstd");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |path| {
        const z = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 28));
        defer gpa.free(z);
        const a = zstd.decode(gpa, z, 1 << 28) catch |e| {
            std.debug.print("ERROR {s} {s}\n", .{ @errorName(e), path });
            continue;
        };
        defer gpa.free(a);
        var s = try zstd.Stream.open(gpa, 8 << 20, 1 << 28);
        defer s.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var pos: usize = 0;
        while (pos < z.len) : (pos += 1000) try s.push(z[pos..@min(pos + 1000, z.len)], &out);
        try s.finish();
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(a, &h, .{});
        const same = std.mem.eql(u8, a, out.items);
        std.debug.print("{s} {} {s}{s}\n", .{ std.fmt.bytesToHex(h, .lower), a.len, path, if (same) "" else " MISMATCH" });
    }
}
