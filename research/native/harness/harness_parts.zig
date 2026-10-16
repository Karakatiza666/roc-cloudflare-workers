//! Size reference: one part of Native alone (build with -Dpart as a root option, see build.sh).
const std = @import("std");
const zstd = @import("native").zstd;
const opts = @import("build_options");
const alloc = @import("alloc");
export fn h_a(p: usize, n: usize) usize {
    const in: [*]const u8 = @ptrFromInt(p);
    switch (opts.part) {
        0 => { // zstd only
            const o = zstd.decode(alloc.allocator, in[0..n], 1 << 20) catch return 0;
            return o.len;
        },
        1 => {
            var h = std.crypto.hash.Blake3.init(.{});
            h.update(in[0..n]);
            var d: [32]u8 = undefined;
            h.final(&d);
            return d[0];
        },
        else => {
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(in[0..n], &d, .{});
            return d[0];
        },
    }
}
