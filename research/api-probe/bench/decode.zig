//! Lower bound for a host-side decoder (API.md 12): decode rows.bin into a tree with the
//! memory shape of Roc values (24 B str and list headers, an 8 B refcount before each heap
//! block, strings of up to 23 B inline), with UTF-8 checks. Native, libc malloc.
const std = @import("std");

const Str = extern struct { ptr: ?[*]u8, len: usize, cap: usize };
const List = extern struct { ptr: ?[*]Node, len: usize, cap: usize };
const Node = extern struct { payload: extern union { f: f64, i: i64, s: Str, l: List, r: u32 }, tag: u8 };

const Err = error{ Bad, OutOfMemory };

fn heap(comptime T: type, n: usize) Err![*]T {
    const raw = std.c.malloc(8 + n * @sizeOf(T)) orelse return error.OutOfMemory;
    const p: [*]u8 = @ptrCast(raw);
    @as(*usize, @ptrCast(@alignCast(p))).* = 1; // refcount
    return @ptrCast(@alignCast(p + 8));
}

const D = struct {
    b: []const u8,
    at: usize = 0,
    fn u32_(d: *D) Err!u32 {
        if (d.at + 4 > d.b.len) return error.Bad;
        const v = std.mem.readInt(u32, d.b[d.at..][0..4], .little);
        d.at += 4;
        return v;
    }
    fn str(d: *D) Err!Str {
        const n = try d.u32_();
        if (d.at + n > d.b.len) return error.Bad;
        const s = d.b[d.at .. d.at + n];
        d.at += n;
        if (!std.unicode.utf8ValidateSlice(s)) return error.Bad;
        if (n <= 23) {
            var out: Str = undefined;
            const o: [*]u8 = @ptrCast(&out);
            @memcpy(o[0..n], s);
            o[23] = @as(u8, @intCast(n)) | 0x80;
            return out;
        }
        const p = try heap(u8, n);
        @memcpy(p[0..n], s);
        return .{ .ptr = p, .len = n, .cap = n };
    }
    fn node(d: *D) Err!Node {
        if (d.at >= d.b.len) return error.Bad;
        const t = d.b[d.at];
        d.at += 1;
        var n: Node = .{ .payload = .{ .i = 0 }, .tag = t };
        switch (t) {
            0...3 => {},
            4, 5 => {
                if (d.at + 8 > d.b.len) return error.Bad;
                n.payload.i = std.mem.readInt(i64, d.b[d.at..][0..8], .little);
                d.at += 8;
            },
            6, 7 => n.payload.s = try d.str(),
            8 => {
                const len = try d.u32_();
                const p = try heap(Node, len);
                for (0..len) |i| p[i] = try d.node();
                n.payload.l = .{ .ptr = p, .len = len, .cap = len };
            },
            10 => n.payload.r = try d.u32_(),
            else => return error.Bad, // objects and errors are not in rows.bin
        }
        return n;
    }
};

// Free the tree, as Roc would when the decoded value is dropped.
fn free(n: Node) void {
    switch (n.tag) {
        6, 7 => if (n.payload.s.cap != 0 and @as([*]u8, @ptrCast(@constCast(&n.payload.s)))[23] & 0x80 == 0) std.c.free(@ptrCast(n.payload.s.ptr.? - 8)),
        8 => {
            const l = n.payload.l;
            for (0..l.len) |i| free(l.ptr.?[i]);
            std.c.free(@ptrCast(@as([*]u8, @ptrCast(l.ptr.?)) - 8));
        },
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "rows.bin", init.gpa, .unlimited);
    const reps = 300;
    var best: u64 = std.math.maxInt(u64);
    var ok: usize = 0;
    for (0..7) |_| {
        const t0 = std.Io.Clock.awake.now(io);
        for (0..reps) |_| {
            var d = D{ .b = bytes };
            const n = try d.node();
            if (d.at == bytes.len and n.tag == 8 and n.payload.l.len == 200) ok += 1;
            free(n);
        }
        const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        best = @min(best, ns / reps);
    }
    std.debug.print("Zig decode to a Roc-shaped tree, then free: {d} µs (ok {d} of {d})\n", .{ best / 1000, ok, 7 * reps });
}
