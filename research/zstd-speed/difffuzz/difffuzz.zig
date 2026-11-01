//! Differential fuzz: zaxified (pure Zig, ReleaseSafe: every bounds check on) against libzstd 1.5.7 (C).
//! Damaged copies of real frames go through both one-shot decoders. Both must give the same bytes or both an error.
//! A panic of the Zig decoder stops the run (a bounds check that hit). Usage: difffuzz <iterations> <seed> <file.zst>...
const std = @import("std");
const Z = @import("zz");

extern fn ZSTD_createDCtx() ?*anyopaque;
extern fn ZSTD_decompressDCtx(d: *anyopaque, dst: [*]u8, cap: usize, src: [*]const u8, len: usize) usize;
extern fn ZSTD_isError(r: usize) c_uint;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iters = try std.fmt.parseInt(usize, args[1], 10);
    const seed = try std.fmt.parseInt(u64, args[2], 10);
    var files: std.ArrayList([]u8) = .empty;
    for (args[3..]) |p| try files.append(gpa, try std.Io.Dir.cwd().readFileAlloc(init.io, p, gpa, .unlimited));
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const cap = 8 << 20;
    const a = try gpa.alloc(u8, cap);
    const b = try gpa.alloc(u8, cap);
    const dctx = ZSTD_createDCtx().?;
    var d = try Z.Decompressor.init(gpa, .{});
    var n_ok: usize = 0;
    var n_err: usize = 0;
    var n_diff: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    for (0..iters) |it| {
        const f = files.items[r.uintLessThan(usize, files.items.len)];
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, f);
        switch (r.uintLessThan(u8, 4)) {
            0 => for (0..1 + r.uintLessThan(usize, 8)) |_| { // byte changes
                buf.items[r.uintLessThan(usize, buf.items.len)] = r.int(u8);
            },
            1 => for (0..1 + r.uintLessThan(usize, 4)) |_| { // bit flips near the start (headers, tables)
                const i = r.uintLessThan(usize, @min(buf.items.len, 512));
                buf.items[i] ^= @as(u8, 1) << r.int(u3);
            },
            2 => buf.items.len = r.uintLessThan(usize, buf.items.len), // cut
            else => { // copy a run of bytes from another place
                const n = 1 + r.uintLessThan(usize, 64);
                if (buf.items.len > n * 2) {
                    const s = r.uintLessThan(usize, buf.items.len - n);
                    const t = r.uintLessThan(usize, buf.items.len - n);
                    std.mem.copyForwards(u8, buf.items[t..][0..n], buf.items[s..][0..n]);
                }
            },
        }
        const in = buf.items;
        const rc = ZSTD_decompressDCtx(dctx, a.ptr, cap, in.ptr, in.len);
        const c_ok = ZSTD_isError(rc) == 0;
        const z = d.decompress(b, in);
        const z_ok = if (z) |_| true else |_| false;
        if (c_ok != z_ok or (c_ok and (rc != (z catch unreachable) or !std.mem.eql(u8, a[0..rc], b[0..rc])))) {
            n_diff += 1;
            if (n_diff <= 10) std.debug.print("diff at {d}: c_ok={} z={any}\n", .{ it, c_ok, z });
        } else if (c_ok) n_ok += 1 else n_err += 1;
    }
    std.debug.print("iterations {d}: same ok {d}, same error {d}, differ {d}\n", .{ iters, n_ok, n_err, n_diff });
}
