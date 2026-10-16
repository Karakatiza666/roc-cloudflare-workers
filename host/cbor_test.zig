//! Native tests of the CBOR codec of the host (API.md 5.1: HD5, HD6 natively, HD7), with the 64-bit layout
//! of the glue. The testing allocator fails a test that leaks (a refcount that is wrong by one).
//! Run: `$ZIG test host/cbor_test.zig` (bench/cbor-zig-test.sh).
const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const C = @import("cbor.zig").Codec(abi);
const Fault = @import("cbor.zig").Fault;

const T = struct {
    env: abi.RocEnv,
    host: abi.RocHost,

    fn init(t: *T) void {
        t.env = .{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
        t.host = abi.makeRocHost(&t.env);
    }

    /// Decode, then encode again. The caller frees the result. Error: the fault.
    fn round(t: *T, bytes: []const u8) ![]u8 {
        switch (C.decode(bytes, &t.host)) {
            .problem => |p| {
                lastFault = p.fault;
                return error.Problem;
            },
            .value => |v| {
                defer v.decref(&t.host);
                const n = C.encodedSize(&v) orelse return error.Deep;
                const out = try std.testing.allocator.alloc(u8, n);
                C.encode(&v, out);
                return out;
            },
        }
    }
};
var lastFault: Fault = .none;

fn unhex(comptime h: []const u8) [h.len / 2]u8 {
    var out: [h.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, h) catch unreachable;
    return out;
}

fn expectRound(t: *T, comptime h: []const u8, comptime want: []const u8) !void {
    const got = t.round(&unhex(h)) catch |e| {
        std.debug.print("{s}: {s} {s}\n", .{ h, @errorName(e), @tagName(lastFault) });
        return e;
    };
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &unhex(want), got);
}

fn expectFault(t: *T, comptime h: []const u8, f: Fault) !void {
    if (t.round(&unhex(h))) |got| {
        std.testing.allocator.free(got);
        std.debug.print("{s}: a value, want {s}\n", .{ h, @tagName(f) });
        return error.TestUnexpectedResult;
    } else |_| {
        if (lastFault != f) std.debug.print("{s}: {s}, want {s}\n", .{ h, @tagName(lastFault), @tagName(f) });
        try std.testing.expectEqual(f, lastFault);
    }
}

fn num(t: *T, comptime h: []const u8) !f64 {
    const d = C.decode(&unhex(h), &t.host);
    const v = d.value;
    defer v.decref(&t.host);
    try std.testing.expectEqual(abi.JsTag.Num, v.tag);
    return v.payload_num();
}

test "HD7 RFC 8949 A: the vectors in the profile are written back the same (integers in the i64 range)" {
    var t: T = undefined;
    t.init();
    inline for (.{
        "00",                 "01",                 "0a",          "17",       "1818",       "1819",     "1864",         "1903e8",
        "1a000f4240",         "1b000000e8d4a51000", "20",          "29",       "3863",       "3903e7",   "fb3ff199999999999a",
        "fb7e37e43c8800759c", "fbc010666666666666", "fb7ff0000000000000",      "fb7ff8000000000000",     "fbfff0000000000000",
        "f4",                 "f5",                 "f6",          "f7",       "40",         "4401020304", "60",           "6161",
        "6449455446",         "62225c",             "62c3bc",      "63e6b0b4", "64f0908591", "80",       "83010203",     "8301820203820405",
        "98190102030405060708090a0b0c0d0e0f101112131415161718181819",
        "a0",                 "a26161016162820203", "826161a161626163",
        "a56161614161626142616361436164614461656145",
        "d818456449455446", // tag 24: Packed, the bytes are kept as they are
    }) |h| try expectRound(&t, h, h);
}

test "HD7 RFC 8949 A: floats of each width read as F64 (f16, f32), and are written as f64" {
    var t: T = undefined;
    t.init();
    try std.testing.expectEqual(@as(f64, 1.5), try num(&t, "f93e00"));
    try std.testing.expectEqual(@as(f64, 65504), try num(&t, "f97bff"));
    try std.testing.expectEqual(@as(f64, 100000), try num(&t, "fa47c35000"));
    try std.testing.expectEqual(@as(f64, 3.4028234663852886e+38), try num(&t, "fa7f7fffff"));
    try std.testing.expectEqual(@as(f64, 5.960464477539063e-8), try num(&t, "f90001"));
    try std.testing.expectEqual(@as(f64, 0.00006103515625), try num(&t, "f90400"));
    try std.testing.expectEqual(@as(f64, -4), try num(&t, "f9c400"));
    try std.testing.expect(std.math.isPositiveInf(try num(&t, "f97c00")));
    try std.testing.expect(std.math.isNegativeInf(try num(&t, "faff800000")));
    try std.testing.expect(std.math.isNan(try num(&t, "f97e00")));
    try std.testing.expect(std.math.isNegativeZero(try num(&t, "f98000")));
    try expectRound(&t, "f93e00", "fb3ff8000000000000");
    // One NaN: other NaN bits are written as the NaN of JS.
    try expectRound(&t, "fb7ff8000000000001", "fb7ff8000000000000");
}

test "HD7 RFC 8949 A: another width of argument reads as the same value" {
    var t: T = undefined;
    t.init();
    try expectRound(&t, "1800", "00");
    try expectRound(&t, "190001", "01");
    try expectRound(&t, "1a00000001", "01");
    try expectRound(&t, "1b0000000000000001", "01");
    try expectRound(&t, "3800", "20");
    try expectRound(&t, "3b0000000000000000", "20");
    try expectRound(&t, "5800", "40");
    try expectRound(&t, "780161", "6161");
    try expectRound(&t, "98020102", "820102");
    try expectRound(&t, "9a00000001f6", "81f6");
    try expectRound(&t, "bb0000000000000001616101", "a1616101");
    try expectRound(&t, "d9001841" ++ "00", "d8184100");
    try expectRound(&t, "db000000000000001841" ++ "00", "d8184100");
}

test "J1: integers at the edges of i64; outside is an error (Int holds an I64)" {
    var t: T = undefined;
    t.init();
    try expectRound(&t, "1b7fffffffffffffff", "1b7fffffffffffffff");
    try expectRound(&t, "3b7fffffffffffffff", "3b7fffffffffffffff");
    try expectFault(&t, "1b8000000000000000", .range);
    try expectFault(&t, "3b8000000000000000", .range);
    try expectFault(&t, "1bffffffffffffffff", .range);
    try expectFault(&t, "3bffffffffffffffff", .range);
}

test "HD7 RFC 8949 A: not in the profile is an error" {
    var t: T = undefined;
    t.init();
    inline for (.{ "c249010000000000000000", "c349010000000000000000", "c074323031332d30332d32315432303a30343a30305a", "c11a514b67b0", "c1fb41d452d9ec200000", "d74401020304", "d82076687474703a2f2f7777772e6578616d706c652e636f6d", "f0", "f8ff", "e0", "f3" }) |h| try expectFault(&t, h, .profile);
    try expectFault(&t, "a201020304", .key);
    inline for (.{ "5f42010243030405ff", "7f657374726561646d696e67ff", "9fff", "9f018202039f0405ffff", "9f01820203820405ff", "83018202039f0405ff", "83019f0203ff820405", "9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff", "bf61610161629f0203ffff", "826161bf61626163ff", "bf6346756ef563416d7421ff", "ff" }) |h| try expectFault(&t, h, .indefinite);
    inline for (.{ "1c", "3d", "5e", "7c", "9d", "be", "dc", "fd" }) |h| try expectFault(&t, h, .reserved);
}

test "profile: tags 27 and 24" {
    var t: T = undefined;
    t.init();
    try expectRound(&t, "d81b826352656601", "d81b826352656601"); // Ref 1
    try expectRound(&t, "d81b8263526566" ++ "1affffffff", "d81b8263526566" ++ "1affffffff"); // Ref maxInt(u32)
    try expectRound(&t, "d81b83654572726f72" ++ "6454797065" ++ "6178", "d81b83654572726f72" ++ "6454797065" ++ "6178"); // Error("Type", "x")
    try expectFault(&t, "d81b8263526566" ++ "1b0000000100000000", .tag); // a Ref id above u32
    try expectFault(&t, "d81b82635265662001", .tag); // a Ref id below 0
    try expectFault(&t, "d81b8263526566" ++ "6161", .tag);
    try expectFault(&t, "d81b8163526566", .tag); // ["Ref"]
    try expectFault(&t, "d81b836352656601" ++ "02", .tag); // ["Ref", 1, 2]
    try expectFault(&t, "d81b82645265665801", .tag); // kind "Ref" with a wrong length is another kind
    try expectFault(&t, "d81b8201" ++ "02", .tag);
    try expectFault(&t, "d81b01", .tag);
    try expectFault(&t, "d8186161", .tag); // tag 24 with text
    try expectFault(&t, "d81b83654572726f72" ++ "01" ++ "6178", .key);
}

test "profile: UTF-8, lengths, cut input, trailing bytes, depth" {
    var t: T = undefined;
    t.init();
    try expectFault(&t, "62c328", .bad_utf8);
    try expectFault(&t, "63eda080", .bad_utf8); // a surrogate
    try expectFault(&t, "62c0af", .bad_utf8); // an overlong form
    try expectFault(&t, "a162c3280a", .bad_utf8); // a key
    try expectFault(&t, "5affffffff", .length);
    try expectFault(&t, "9affffffff", .length);
    try expectFault(&t, "a3616101", .length);
    try expectFault(&t, "8301", .length);
    try expectFault(&t, "a16161", .cut);
    try expectFault(&t, "", .cut);
    try expectFault(&t, "19", .cut);
    try expectFault(&t, "fb3ff1", .cut);
    try expectFault(&t, "0101", .trailing);
    // 64 containers are in the profile, 65 are not.
    try expectRound(&t, rep("81", 63) ++ "80", rep("81", 63) ++ "80");
    try expectFault(&t, rep("81", 64) ++ "80", .depth);
    try expectFault(&t, rep("a16161", 64) ++ "a0", .depth);
}

test "J3: the encoder refuses a tree deeper than 64 containers" {
    var t: T = undefined;
    t.init();
    var v = C.make(.Arr, abi.RocList(abi.Js), abi.RocList(abi.Js).empty());
    for (0..64) |_| {
        const l = abi.RocList(abi.Js).allocate(1, &t.host);
        l.elements_ptr.?[0] = v;
        v = C.make(.Arr, abi.RocList(abi.Js), l);
    }
    defer v.decref(&t.host);
    try std.testing.expectEqual(@as(?usize, null), C.encodedSize(&v));
    const inner = v.payload_arr().items()[0];
    try std.testing.expectEqual(@as(?usize, 64), C.encodedSize(&inner)); // 64 levels: 63 heads of 1 B and the empty array
}

/// Fixtures with each kind of value, for the mutations of the fuzz test.
const fixtures = [_][]const u8{
    &unhex("a56161614161626142616361436164614461656145"),
    &unhex("8301820203820405"),
    &unhex("a3647465787478216c6f6e6720746578742077697468206d6f7265207468616e2032332062797465736262794401020304636269673b7ffffffffffffffe"),
    &unhex("86f4f5f6f7fb3ff199999999999af93e00"),
    &unhex("83d81b826352656607d81b8365457272" ++ "6f72" ++ "6454797065" ++ "6178" ++ "d818456449455446"),
    &unhex("a26172a2617801617982f6f7616b8263e6b0b464f0908591"),
};

test "HD5: random and cut bytes give an error or a value, never a trap or a read past the input; a value encodes and decodes the same" {
    var t: T = undefined;
    t.init();
    var prng = std.Random.DefaultPrng.init(0x5eed_cb08);
    const r = prng.random();
    var buf: [96]u8 = undefined;
    var values: usize = 0;
    var problems: usize = 0;
    for (0..200_000) |i| {
        var len: usize = undefined;
        if (i % 2 == 0) {
            // Random bytes, biased to the heads of the profile.
            len = r.uintLessThan(usize, 40);
            for (buf[0..len]) |*b| b.* = if (r.boolean()) r.int(u8) else @as(u8, r.uintLessThan(u8, 8)) << 5 | r.uintLessThan(u8, 28);
        } else {
            // A fixture with a cut, a changed byte, or both.
            const f = fixtures[r.uintLessThan(usize, fixtures.len)];
            @memcpy(buf[0..f.len], f);
            len = f.len;
            if (r.boolean()) buf[r.uintLessThan(usize, len)] = r.int(u8);
            if (r.boolean()) len = r.uintLessThan(usize, len + 1);
        }
        // An input with no room after it: a read past it is a bounds failure of the slice.
        const in = try std.testing.allocator.dupe(u8, buf[0..len]);
        defer std.testing.allocator.free(in);
        if (t.round(in)) |once| {
            defer std.testing.allocator.free(once);
            const twice = try t.round(once);
            defer std.testing.allocator.free(twice);
            try std.testing.expectEqualSlices(u8, once, twice);
            values += 1;
        } else |e| {
            try std.testing.expectEqual(error.Problem, e);
            problems += 1;
        }
    }
    try std.testing.expect(values > 10_000 and problems > 10_000);
}

test "HD5: each prefix of each fixture is an error, the whole is a value" {
    var t: T = undefined;
    t.init();
    for (fixtures) |f| {
        for (0..f.len) |n| {
            const in = try std.testing.allocator.dupe(u8, f[0..n]);
            defer std.testing.allocator.free(in);
            try std.testing.expectError(error.Problem, t.round(in));
        }
        const whole = try t.round(f);
        std.testing.allocator.free(whole);
    }
}

test "HD6 (native): 10,000 decodes of the fixtures and a drop free all bytes" {
    var t: T = undefined;
    t.init();
    for (0..10_000) |i| {
        const d = C.decode(fixtures[i % fixtures.len], &t.host);
        d.value.decref(&t.host);
    }
}

fn rep(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}
