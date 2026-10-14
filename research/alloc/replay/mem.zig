//! Raw memory access and Roc string layout (wasm32).

const std = @import("std");

pub inline fn rd8(a: usize) u8 {
    return @as(*const u8, @ptrFromInt(a)).*;
}
pub inline fn wr8(a: usize, v: u8) void {
    @as(*u8, @ptrFromInt(a)).* = v;
}
pub inline fn rd32(a: usize) u32 {
    return @as(*align(1) const u32, @ptrFromInt(a)).*;
}
pub inline fn wr32(a: usize, v: u32) void {
    @as(*align(1) u32, @ptrFromInt(a)).* = v;
}
pub inline fn rdUsize(a: usize) usize {
    return @as(*align(1) const usize, @ptrFromInt(a)).*;
}
pub inline fn wrUsize(a: usize, v: usize) void {
    @as(*align(1) usize, @ptrFromInt(a)).* = v;
}
/// Replay: bytes copied by realloc.
pub var COPY_BYTES: u64 = 0;
pub var COPIES: u64 = 0;
pub inline fn copyBytes(dst: usize, src: usize, len: usize) void {
    if (len == 0) return;
    COPY_BYTES += len;
    COPIES += 1;
    const d: [*]u8 = @ptrFromInt(dst);
    const s: [*]const u8 = @ptrFromInt(src);
    @memcpy(d[0..len], s[0..len]);
}
pub inline fn trap() noreturn {
    @trap();
}

/// Set by a trap that leaves the heap sound (Roc `crash`, stack canary, out of
/// memory). Any other trap may follow a corrupt write, so the host retires the instance.
pub var TRAP_CLEAN: bool = false;
pub inline fn trapClean() noreturn {
    TRAP_CLEAN = true;
    @trap();
}

pub inline fn alignUp(n: usize, a0: usize) usize {
    const a = if (a0 == 0) 1 else a0;
    return (n + a - 1) & ~(a - 1);
}

/// Offset of `field` in `T`, with a compile-time check of the field type.
pub fn fieldOff(comptime T: type, comptime field: []const u8, comptime Want: type) usize {
    if (@FieldType(T, field) != Want)
        @compileError(@typeName(T) ++ "." ++ field ++ " is not " ++ @typeName(Want));
    return @offsetOf(T, field);
}

/// Element type of a generated RocList type.
pub fn ListElem(comptime L: type) type {
    return @typeInfo(@typeInfo(@FieldType(L, "elements_ptr")).optional.child).pointer.child;
}

/// Increment the refcount word before `data_ptr`. 0 marks static data.
pub inline fn incref(data_ptr: usize) void {
    if (data_ptr == 0) return;
    const rc: *isize = @ptrFromInt(data_ptr - @sizeOf(isize));
    if (rc.* != 0) rc.* += 1;
}

pub const Span = struct { p: usize, l: usize };

// RocStr on wasm32: bytes @0, capacity @4, length @8. A host checks its generated type with `checkStr`.
pub const STR_SIZE: usize = 3 * @sizeOf(usize);
const STR_BYTES: usize = 0;
const STR_LEN: usize = 2 * @sizeOf(usize);

pub fn checkStr(comptime RocStr: type) void {
    comptime {
        if (@sizeOf(RocStr) != STR_SIZE or @offsetOf(RocStr, "bytes") != STR_BYTES or @offsetOf(RocStr, "length") != STR_LEN)
            @compileError("RocStr layout changed");
    }
}

/// (data_ptr, len) of the RocStr at `off`. A small string lives inline at `off`.
pub inline fn strAt(off: usize) Span {
    const len_word = rdUsize(off + STR_LEN);
    if (@as(isize, @bitCast(len_word)) < 0) {
        return .{ .p = off, .l = rd8(off + STR_SIZE - 1) ^ 0x80 };
    }
    return .{ .p = rdUsize(off + STR_BYTES), .l = len_word };
}

pub fn bytesEqLen(a: usize, b: usize, len: usize) bool {
    var i: usize = 0;
    while (i + 4 <= len) : (i += 4) {
        if (rd32(a + i) != rd32(b + i)) return false;
    }
    while (i < len) : (i += 1) {
        if (rd8(a + i) != rd8(b + i)) return false;
    }
    return true;
}

pub inline fn bytesEq(ap: usize, al: usize, bp: usize, bl: usize) bool {
    return al == bl and bytesEqLen(ap, bp, al);
}

/// Equal RocStr values at `a` and `b`.
pub fn strEq(a: usize, b: usize) bool {
    const x = strAt(a);
    const y = strAt(b);
    if (x.l != y.l) return false;
    if (x.p == y.p) return true;
    return bytesEqLen(x.p, y.p, x.l);
}

pub fn fnv1a(ptr: usize, len: usize) u32 {
    var h: u32 = 2166136261;
    for (0..len) |i| {
        h ^= rd8(ptr + i);
        h *%= 16777619;
    }
    return h;
}

test "bytesEq and fnv1a" {
    const a = "hello world";
    const b = "hello world";
    try std.testing.expect(bytesEq(@intFromPtr(a.ptr), a.len, @intFromPtr(b.ptr), b.len));
    try std.testing.expect(!bytesEq(@intFromPtr(a.ptr), a.len, @intFromPtr(b.ptr), b.len - 1));
    try std.testing.expectEqual(fnv1a(@intFromPtr(a.ptr), a.len), fnv1a(@intFromPtr(b.ptr), b.len));
}
