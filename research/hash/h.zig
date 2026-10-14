const std = @import("std");
var buf: [4 << 20]u8 = undefined;
export fn fill() void {
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761);
}
export fn wy(len: usize, iters: u32) u64 {
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < iters) : (i += 1) acc +%= std.hash.Wyhash.hash(i, buf[0..len]);
    return acc;
}
export fn xx3(len: usize, iters: u32) u64 {
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < iters) : (i += 1) acc +%= std.hash.XxHash3.hash(i, buf[0..len]);
    return acc;
}
export fn crc(len: usize, iters: u32) u64 {
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < iters) : (i += 1) acc +%= std.hash.Crc32.hash(buf[0..len]);
    return acc;
}
export fn copy(len: usize, iters: u32) u64 {
    var i: u32 = 0;
    while (i < iters) : (i += 1) @memcpy(buf[len .. 2 * len], buf[0..len]);
    return buf[len];
}
