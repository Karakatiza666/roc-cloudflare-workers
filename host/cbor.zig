//! The CBOR profile of API.md 5 in the host: a `Js` tree (the Roc values of the glue) to bytes, and bytes
//! to a `Js` tree. Generic over the glue module, so the native tests (`host/cbor_test.zig`) use the
//! 64-bit layout and the host uses the wasm32 layout of the same file.
//!
//! Profile (as `js/cbor.js`): definite lengths only; the reader takes any width of an argument and
//! f16, f32, f64; the writer writes the shortest width and floats as f64. Tags 27 (`["Ref", id]`,
//! `["Error", name, message]`) and 24 (`Packed`: a byte string). Depth: 64 containers or less.
//! Text must be valid UTF-8. Bytes after the value are an error. An integer outside the i64 range
//! is an error (`Int` holds an I64). The content of a `Packed` is not read: `Cbor.parse` reads it.

const std = @import("std");

pub const MAX_DEPTH = 64;

pub const Fault = enum(u8) {
    none,
    /// The input ends before the value.
    cut,
    /// A length that is longer than the rest of the input.
    length,
    /// An indefinite length or a break (info 31).
    indefinite,
    /// Additional information 28 to 30.
    reserved,
    /// A tag that is not 24 or 27, a simple value that is not in the profile.
    profile,
    /// Tag 27 that is not `["Ref", u32]` or `["Error", text, text]`, tag 24 with no byte string.
    tag,
    /// A map key that is not text.
    key,
    bad_utf8,
    /// An integer outside the i64 range.
    range,
    depth,
    trailing,

    pub fn text(f: Fault) []const u8 {
        return switch (f) {
            .none => "no error",
            .cut => "input ends inside a value",
            .length => "length is longer than the input",
            .indefinite => "indefinite length (or break) is not in the profile",
            .reserved => "reserved additional information",
            .profile => "tag or simple value is not in the profile",
            .tag => "tag 27 is not [\"Ref\", id] or [\"Error\", name, message], or tag 24 has no byte string",
            .key => "a map key must be text",
            .bad_utf8 => "text is not valid UTF-8",
            .range => "integer is outside the i64 range",
            .depth => "value is deeper than 64 levels",
            .trailing => "bytes after the value",
        };
    }
};

pub fn Codec(comptime abi: type) type {
    return struct {
        const Js = abi.Js;
        const Tag = abi.JsTag;
        const RocStr = abi.RocStr;
        const Bytes = abi.RocListWith(u8, false);
        const List = abi.RocList(Js);
        const Field = abi.JsObj;
        const Fields = abi.RocList(Field);
        const Host = abi.RocHost;

        // HD1: the decoder writes these payloads in place. A changed glue fails the build here.
        comptime {
            if (@sizeOf(usize) == 4) {
                std.debug.assert(@sizeOf(Js) == 32 and @offsetOf(Js, "tag") == 24 and @alignOf(Js) == 8);
                std.debug.assert(@sizeOf(RocStr) == 12 and @sizeOf(Field) == 48);
            }
            std.debug.assert(@offsetOf(Field, "_1") == 0 and @offsetOf(Field, "_0") == @sizeOf(Js));
            std.debug.assert(@sizeOf(abi.JsRef) == 4);
            for (.{ "Arr", "Bool", "Bytes", "Error", "Int", "Null", "Num", "Obj", "Packed", "Ref", "Text", "Undefined" }) |name| {
                _ = @field(Tag, name);
            }
            std.debug.assert(@typeInfo(Tag).@"enum".field_names.len == 12);
        }

        fn payload(v: *Js, comptime T: type) *T {
            return @ptrCast(@alignCast(&v.payload));
        }
        fn payloadOf(v: *const Js, comptime T: type) *const T {
            return @ptrCast(@alignCast(&v.payload));
        }

        pub fn make(tag: Tag, comptime T: type, p: T) Js {
            var v: Js = undefined;
            @memset(std.mem.asBytes(&v.payload), 0);
            v.tag = tag;
            if (T != void) payload(&v, T).* = p;
            return v;
        }
        pub fn simple(tag: Tag) Js {
            return make(tag, void, {});
        }
        /// `Error(name, message)`, for the host's own errors (status 1 and 3).
        pub fn errorValue(name: []const u8, message: []const u8, host: *Host) Js {
            return make(.Error, abi.JsErrorPayload, .{ ._0 = RocStr.fromSlice(name, host), ._1 = RocStr.fromSlice(message, host) });
        }

        // ------------------------------------------------------------ encode

        fn headLen(x: u64) usize {
            if (x < 24) return 1;
            if (x < 0x100) return 2;
            if (x < 0x10000) return 3;
            if (x < 0x100000000) return 5;
            return 9;
        }

        fn strSlice(s: *const RocStr) []const u8 {
            return s.asSlice();
        }

        const REF_HEAD = [_]u8{ 0xd8, 0x1b, 0x82, 0x63, 'R', 'e', 'f' };
        const ERROR_HEAD = [_]u8{ 0xd8, 0x1b, 0x83, 0x65, 'E', 'r', 'r', 'o', 'r' };

        /// The size of the CBOR of `v`, or null when it is deeper than MAX_DEPTH (J3).
        pub fn encodedSize(v: *const Js) ?usize {
            return sizeAt(v, 0);
        }

        fn sizeAt(v: *const Js, level: usize) ?usize {
            return switch (v.tag) {
                .Undefined, .Null, .Bool => 1,
                .Num => 9,
                .Int => blk: {
                    const n = payloadOf(v, i64).*;
                    break :blk headLen(if (n >= 0) @intCast(n) else @intCast(-1 - n));
                },
                .Text => blk: {
                    const l = strSlice(payloadOf(v, RocStr)).len;
                    break :blk headLen(l) + l;
                },
                .Bytes, .Packed => blk: {
                    const l = payloadOf(v, Bytes).length;
                    break :blk headLen(l) + l + @as(usize, if (v.tag == .Packed) 2 else 0);
                },
                .Ref => REF_HEAD.len + headLen(payloadOf(v, abi.JsRef).id),
                .Error => blk: {
                    const e = payloadOf(v, abi.JsErrorPayload);
                    const a = strSlice(&e._0).len;
                    const b = strSlice(&e._1).len;
                    break :blk ERROR_HEAD.len + headLen(a) + a + headLen(b) + b;
                },
                .Arr => blk: {
                    if (level >= MAX_DEPTH) return null;
                    const items = payloadOf(v, List).items();
                    var n = headLen(items.len);
                    for (items) |*x| n += sizeAt(x, level + 1) orelse return null;
                    break :blk n;
                },
                .Obj => blk: {
                    if (level >= MAX_DEPTH) return null;
                    const fields = payloadOf(v, Fields).items();
                    var n = headLen(fields.len);
                    for (fields) |*f| {
                        const k = strSlice(&f._0).len;
                        n += headLen(k) + k + (sizeAt(&f._1, level + 1) orelse return null);
                    }
                    break :blk n;
                },
            };
        }

        const Out = struct {
            buf: []u8,
            at: usize = 0,

            fn byte(o: *Out, b: u8) void {
                o.buf[o.at] = b;
                o.at += 1;
            }
            fn raw(o: *Out, s: []const u8) void {
                @memcpy(o.buf[o.at..][0..s.len], s);
                o.at += s.len;
            }
            fn head(o: *Out, major: u8, x: u64) void {
                const m = major << 5;
                if (x < 24) return o.byte(m | @as(u8, @intCast(x)));
                if (x < 0x100) {
                    o.byte(m | 24);
                    return o.byte(@intCast(x));
                }
                if (x < 0x10000) {
                    o.byte(m | 25);
                    std.mem.writeInt(u16, o.buf[o.at..][0..2], @intCast(x), .big);
                    o.at += 2;
                    return;
                }
                if (x < 0x100000000) {
                    o.byte(m | 26);
                    std.mem.writeInt(u32, o.buf[o.at..][0..4], @intCast(x), .big);
                    o.at += 4;
                    return;
                }
                o.byte(m | 27);
                std.mem.writeInt(u64, o.buf[o.at..][0..8], x, .big);
                o.at += 8;
            }
            fn text(o: *Out, s: []const u8) void {
                o.head(3, s.len);
                o.raw(s);
            }
        };

        /// Writes `v` into `buf`, which has `encodedSize(v)` bytes.
        pub fn encode(v: *const Js, buf: []u8) void {
            var o = Out{ .buf = buf };
            put(&o, v);
            std.debug.assert(o.at == buf.len);
        }

        fn put(o: *Out, v: *const Js) void {
            switch (v.tag) {
                .Undefined => o.byte(0xf7),
                .Null => o.byte(0xf6),
                .Bool => o.byte(if (payloadOf(v, bool).*) 0xf5 else 0xf4),
                .Num => {
                    o.byte(0xfb);
                    std.mem.writeInt(u64, o.buf[o.at..][0..8], @bitCast(payloadOf(v, f64).*), .big);
                    o.at += 8;
                },
                .Int => {
                    const n = payloadOf(v, i64).*;
                    if (n >= 0) o.head(0, @intCast(n)) else o.head(1, @intCast(-1 - n));
                },
                .Text => o.text(strSlice(payloadOf(v, RocStr))),
                .Bytes => {
                    const b = payloadOf(v, Bytes).items();
                    o.head(2, b.len);
                    o.raw(b);
                },
                .Packed => {
                    const b = payloadOf(v, Bytes).items();
                    o.raw(&.{ 0xd8, 0x18 });
                    o.head(2, b.len);
                    o.raw(b);
                },
                .Ref => {
                    o.raw(&REF_HEAD);
                    o.head(0, payloadOf(v, abi.JsRef).id);
                },
                .Error => {
                    const e = payloadOf(v, abi.JsErrorPayload);
                    o.raw(&ERROR_HEAD);
                    o.text(strSlice(&e._0));
                    o.text(strSlice(&e._1));
                },
                .Arr => {
                    const items = payloadOf(v, List).items();
                    o.head(4, items.len);
                    for (items) |*x| put(o, x);
                },
                .Obj => {
                    const fields = payloadOf(v, Fields).items();
                    o.head(5, fields.len);
                    for (fields) |*f| {
                        o.text(strSlice(&f._0));
                        put(o, &f._1);
                    }
                },
            }
        }

        // ------------------------------------------------------------ decode

        /// A decode error: what and where (the byte offset).
        pub const Problem = struct { fault: Fault, at: usize };

        /// The first pass: the bytes are one value of the profile. It allocates nothing, so the
        /// second pass (`build`) cannot fail, and a bad input leaves no value to free.
        const Checker = struct {
            b: []const u8,
            at: usize = 0,
            fault: Fault = .none,

            fn fail(c: *Checker, f: Fault) error{Bad} {
                c.fault = f;
                return error.Bad;
            }
            fn need(c: *Checker, n: u64) !void {
                if (n > c.b.len - c.at) return c.fail(.cut);
            }
            fn arg(c: *Checker, info: u8) !u64 {
                switch (info) {
                    0...23 => return info,
                    24...27 => {
                        const w = @as(usize, 1) << @intCast(info - 24);
                        try c.need(w);
                        var x: u64 = 0;
                        for (c.b[c.at..][0..w]) |byte| x = (x << 8) | byte;
                        c.at += w;
                        return x;
                    },
                    31 => return c.fail(.indefinite),
                    else => return c.fail(.reserved),
                }
            }
            /// A length: `each` bytes or more for each unit must fit in the rest of the input.
            fn len(c: *Checker, info: u8, each: u64) !usize {
                const n = try c.arg(info);
                if (n > (c.b.len - c.at) / each) return c.fail(.length);
                return @intCast(n);
            }
            fn text(c: *Checker) !void {
                try c.need(1);
                const ib = c.b[c.at];
                if (ib >> 5 != 3) return c.fail(.key);
                c.at += 1;
                try c.str(ib & 31);
            }
            fn str(c: *Checker, info: u8) !void {
                const n = try c.len(info, 1);
                if (!std.unicode.utf8ValidateSlice(c.b[c.at..][0..n])) return c.fail(.bad_utf8);
                c.at += n;
            }
            /// The text of tag 27: the kind.
            fn kind(c: *Checker) ![]const u8 {
                try c.need(1);
                const ib = c.b[c.at];
                if (ib >> 5 != 3) return c.fail(.tag);
                c.at += 1;
                const n = try c.len(ib & 31, 1);
                const s = c.b[c.at..][0..n];
                c.at += n;
                return s;
            }
            fn value(c: *Checker, level: usize) error{Bad}!void {
                try c.need(1);
                const ib = c.b[c.at];
                c.at += 1;
                const info = ib & 31;
                switch (ib >> 5) {
                    0, 1 => if (try c.arg(info) > std.math.maxInt(i64)) return c.fail(.range),
                    2 => {
                        const n = try c.len(info, 1);
                        c.at += n;
                    },
                    3 => try c.str(info),
                    4 => {
                        if (level >= MAX_DEPTH) return c.fail(.depth);
                        const n = try c.len(info, 1);
                        for (0..n) |_| try c.value(level + 1);
                    },
                    5 => {
                        if (level >= MAX_DEPTH) return c.fail(.depth);
                        const n = try c.len(info, 2);
                        for (0..n) |_| {
                            try c.text();
                            try c.value(level + 1);
                        }
                    },
                    6 => switch (try c.arg(info)) {
                        27 => try c.generic(),
                        24 => {
                            try c.need(1);
                            const jb = c.b[c.at];
                            if (jb >> 5 != 2) return c.fail(.tag);
                            c.at += 1;
                            const n = try c.len(jb & 31, 1);
                            c.at += n;
                        },
                        else => return c.fail(.profile),
                    },
                    else => switch (info) {
                        20...23 => {},
                        25 => {
                            try c.need(2);
                            c.at += 2;
                        },
                        26 => {
                            try c.need(4);
                            c.at += 4;
                        },
                        27 => {
                            try c.need(8);
                            c.at += 8;
                        },
                        31 => return c.fail(.indefinite),
                        28...30 => return c.fail(.reserved),
                        else => return c.fail(.profile),
                    },
                }
            }
            fn generic(c: *Checker) !void {
                try c.need(1);
                const ib = c.b[c.at];
                if (ib >> 5 != 4) return c.fail(.tag);
                c.at += 1;
                const n = try c.arg(ib & 31);
                const k = try c.kind();
                if (n == 2 and std.mem.eql(u8, k, "Ref")) {
                    try c.need(1);
                    const jb = c.b[c.at];
                    if (jb >> 5 != 0) return c.fail(.tag);
                    c.at += 1;
                    if (try c.arg(jb & 31) > std.math.maxInt(u32)) return c.fail(.tag);
                    return;
                }
                if (n == 3 and std.mem.eql(u8, k, "Error")) {
                    try c.text();
                    try c.text();
                    return;
                }
                return c.fail(.tag);
            }
        };

        /// Checks that `b` is one value of the profile. Null: it is.
        pub fn check(b: []const u8) ?Problem {
            var c = Checker{ .b = b };
            c.value(0) catch return .{ .fault = c.fault, .at = c.at };
            if (c.at != b.len) return .{ .fault = .trailing, .at = c.at };
            return null;
        }

        /// The second pass: build the Roc values of checked bytes. Allocations go through `host`
        /// (in wasm: the owner of the task, so a trap frees them, PLAN.md 2a, RS4).
        const Builder = struct {
            b: []const u8,
            at: usize = 0,
            host: *Host,

            fn arg(d: *Builder, info: u8) u64 {
                if (info < 24) return info;
                const w = @as(usize, 1) << @intCast(info - 24);
                var x: u64 = 0;
                for (d.b[d.at..][0..w]) |byte| x = (x << 8) | byte;
                d.at += w;
                return x;
            }
            fn slice(d: *Builder, info: u8) []const u8 {
                const n: usize = @intCast(d.arg(info));
                const s = d.b[d.at..][0..n];
                d.at += n;
                return s;
            }
            fn str(d: *Builder) RocStr {
                const ib = d.b[d.at];
                d.at += 1;
                return RocStr.fromSlice(d.slice(ib & 31), d.host);
            }
            /// f16 by its bits: an f16 cast needs a compiler-rt function that the wasm link has not.
            fn half(h: u64) f64 {
                const e = (h >> 10) & 0x1f;
                const m = h & 0x3ff;
                const sign: u64 = (h & 0x8000) << 48;
                if (e == 0) {
                    const x = @as(f64, @floatFromInt(m)) * 0x1p-24;
                    return if (sign != 0) -x else x;
                }
                const e64: u64 = if (e == 31) 0x7ff else e + (1023 - 15);
                return @bitCast(sign | (e64 << 52) | (m << 42));
            }
            fn float(bits: u64, comptime F: type, comptime U: type) f64 {
                const x: f64 = if (F == f16) half(bits) else @floatCast(@as(F, @bitCast(@as(U, @intCast(bits)))));
                // One NaN, as JS has: the bits of a NaN are not data.
                return if (std.math.isNan(x)) std.math.nan(f64) else x;
            }
            fn value(d: *Builder) Js {
                const ib = d.b[d.at];
                d.at += 1;
                const info = ib & 31;
                switch (ib >> 5) {
                    0 => return make(.Int, i64, @intCast(d.arg(info))),
                    1 => return make(.Int, i64, -1 - @as(i64, @intCast(d.arg(info)))),
                    2 => return make(.Bytes, Bytes, Bytes.fromSlice(d.slice(info), d.host)),
                    3 => return make(.Text, RocStr, RocStr.fromSlice(d.slice(info), d.host)),
                    4 => {
                        const n: usize = @intCast(d.arg(info));
                        const list = List.allocate(n, d.host);
                        if (list.elements_ptr) |p| for (0..n) |i| {
                            p[i] = d.value();
                        };
                        return make(.Arr, List, list);
                    },
                    5 => {
                        const n: usize = @intCast(d.arg(info));
                        const list = Fields.allocate(n, d.host);
                        if (list.elements_ptr) |p| for (0..n) |i| {
                            const k = d.str();
                            p[i] = .{ ._1 = d.value(), ._0 = k };
                        };
                        return make(.Obj, Fields, list);
                    },
                    6 => if (d.arg(info) == 24) {
                        const jb = d.b[d.at];
                        d.at += 1;
                        return make(.Packed, Bytes, Bytes.fromSlice(d.slice(jb & 31), d.host));
                    } else {
                        const ab = d.b[d.at];
                        d.at += 1;
                        const n = d.arg(ab & 31);
                        const kb = d.b[d.at];
                        d.at += 1;
                        _ = d.slice(kb & 31);
                        if (n == 2) {
                            const jb = d.b[d.at];
                            d.at += 1;
                            return make(.Ref, abi.JsRef, .{ .id = @intCast(d.arg(jb & 31)) });
                        }
                        const name = d.str();
                        return make(.Error, abi.JsErrorPayload, .{ ._0 = name, ._1 = d.str() });
                    },
                    else => switch (info) {
                        20 => return make(.Bool, bool, false),
                        21 => return make(.Bool, bool, true),
                        22 => return simple(.Null),
                        23 => return simple(.Undefined),
                        25 => return make(.Num, f64, float(d.arg(25), f16, u16)),
                        26 => return make(.Num, f64, float(d.arg(26), f32, u32)),
                        else => return make(.Num, f64, float(d.arg(27), f64, u64)),
                    },
                }
            }
        };

        pub const Decoded = union(enum) { value: Js, problem: Problem };

        /// Bytes to a `Js` value, or the problem. A problem allocates nothing.
        pub fn decode(b: []const u8, host: *Host) Decoded {
            if (check(b)) |p| return .{ .problem = p };
            var d = Builder{ .b = b, .host = host };
            return .{ .value = d.value() };
        }

        /// The text of a problem, for `Error(name, message)`: "CBOR: <what> at byte <n>".
        pub fn problemText(p: Problem, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "CBOR: {s} at byte {d}", .{ p.fault.text(), p.at }) catch "CBOR: bad input";
        }
    };
}
