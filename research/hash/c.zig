const std = @import("std");
const V = @Vector(2, u64);
var buf: [32 << 20]u8 align(16) = undefined;
export fn fill() void {
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761);
}
export fn base() usize {
    return @intFromPtr(&buf);
}
fn vecs(len: usize) []const V {
    return @as([*]const V, @ptrCast(@alignCast(&buf)))[0 .. len / 16];
}
// XOR of all words: any single changed word changes it.
export fn xorv(len: usize) u64 {
    var a: V = @splat(0);
    var b: V = @splat(0);
    const v = vecs(len);
    var i: usize = 0;
    while (i + 1 < v.len) : (i += 2) {
        a ^= v[i];
        b ^= v[i + 1];
    }
    const r = a ^ b;
    return r[0] ^ r[1];
}
// Fletcher style: s1 += w, s2 += s1. Order sensitive, so a swap or a move changes it.
export fn fletch(len: usize) u64 {
    var s1: V = @splat(0);
    var s2: V = @splat(0);
    var t1: V = @splat(0);
    var t2: V = @splat(0);
    const v = vecs(len);
    var i: usize = 0;
    while (i + 1 < v.len) : (i += 2) {
        s1 +%= v[i];
        s2 +%= s1;
        t1 +%= v[i + 1];
        t2 +%= t1;
    }
    return s1[0] ^ (s2[0] *% 3) ^ (s1[1] *% 5) ^ (s2[1] *% 7) ^ (t1[0] *% 11) ^ (t2[0] *% 13) ^ (t1[1] *% 17) ^ (t2[1] *% 19);
}
export fn wy(len: usize) u64 {
    return std.hash.Wyhash.hash(0, buf[0..len]);
}
export fn flip(off: usize) void {
    buf[off] ^= 1;
}
export fn swap(a_: usize, b_: usize) void {
    const t = std.mem.readInt(u64, buf[a_..][0..8], .little);
    std.mem.writeInt(u64, buf[a_..][0..8], std.mem.readInt(u64, buf[b_..][0..8], .little), .little);
    std.mem.writeInt(u64, buf[b_..][0..8], t, .little);
}
