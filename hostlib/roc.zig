//! Roc runtime callbacks, the host context for erased-callable calls, the
//! console log queue, and RocStr values made from JS bytes.

const std = @import("std");
const mem = @import("mem.zig");
const alloc = @import("alloc.zig");
const wordbuf = @import("wordbuf.zig");

pub const LOG_LEVEL_LOG: u32 = 0;
pub const LOG_LEVEL_DBG: u32 = 1;

// Console log queue of (ptr, len, level) triples, drained by JS.
pub var LOG = wordbuf.WordBuf{};

pub fn logPushCopy(ptr: usize, len: usize, level: u32) void {
    const copy = alloc.allocOrTrap(len, 1);
    mem.copyBytes(copy, ptr, len);
    LOG.push(wordbuf.LOG_INITIAL, @intCast(copy));
    LOG.push(wordbuf.LOG_INITIAL, @intCast(len));
    LOG.push(wordbuf.LOG_INITIAL, level);
}

export fn log_ptr() usize {
    return LOG.ptr;
}
export fn log_len() usize {
    return LOG.len;
}
export fn log_clear() void {
    var i: usize = 0;
    while (i + 2 < LOG.len) : (i += 3) {
        const ptr: usize = mem.rd32(LOG.ptr + i * 4);
        if (ptr != 0) alloc.hostDealloc(ptr);
    }
    LOG.len = 0;
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    logPushCopy(@intFromPtr(bytes), len, LOG_LEVEL_DBG);
}
export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = .{ bytes, len };
}

/// Set by a host that wants the crash message in the log before the trap.
pub var LOG_CRASH: bool = false;

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    if (LOG_CRASH) logPushCopy(@intFromPtr(bytes), len, LOG_LEVEL_LOG);
    mem.trapClean();
}

/// The host context for erased-callable calls, for the generated `RocHost` type.
/// Compiled Roc code ignores it.
pub fn RocHostOf(comptime RocHost: type) type {
    return struct {
        fn ctxAlloc(_: *RocHost, len: usize, a: usize) callconv(.c) *anyopaque {
            alloc.ROC_BYTES += len;
            return @ptrFromInt(alloc.allocOrTrap(len, a));
        }
        fn ctxDealloc(_: *RocHost, p: *anyopaque, _: usize) callconv(.c) void {
            alloc.hostDealloc(@intFromPtr(p));
        }
        fn ctxRealloc(_: *RocHost, p: *anyopaque, len: usize, a: usize) callconv(.c) *anyopaque {
            const q = alloc.reallocOrTrap(@intFromPtr(p), len, a);
            if (q != @intFromPtr(p)) alloc.ROC_BYTES += len;
            return @ptrFromInt(q);
        }
        fn ctxDbg(_: *RocHost, b: [*]const u8, l: usize) callconv(.c) void {
            roc_dbg(b, l);
        }
        fn ctxExpect(_: *RocHost, _: [*]const u8, _: usize) callconv(.c) void {}
        fn ctxCrashed(_: *RocHost, b: [*]const u8, l: usize) callconv(.c) void {
            roc_crashed(b, l);
        }
        var env: u8 = 0;
        pub var host = RocHost{
            .env = @ptrCast(&env),
            .roc_alloc = &ctxAlloc,
            .roc_dealloc = &ctxDealloc,
            .roc_realloc = &ctxRealloc,
            .roc_dbg = &ctxDbg,
            .roc_expect_failed = &ctxExpect,
            .roc_crashed = &ctxCrashed,
        };
    };
}

/// RocStr constructors for the generated `RocStr` type.
pub fn StrOf(comptime RocStr: type) type {
    mem.checkStr(RocStr);
    return struct {
        /// A RocStr copied out of memory. Up to 11 bytes become a small string.
        pub fn copied(ptr: usize, len: usize) RocStr {
            if (len <= mem.STR_SIZE - 1) {
                var s = RocStr{ .bytes = null, .capacity_or_alloc_ptr = 0, .length = 0 };
                const dst: [*]u8 = @ptrCast(&s);
                for (0..len) |i| dst[i] = mem.rd8(ptr + i);
                dst[mem.STR_SIZE - 1] = @as(u8, @intCast(len)) | 0x80;
                return s;
            }
            const block = alloc.allocOrTrap(4 + len, 4);
            mem.wrUsize(block, 1);
            mem.copyBytes(block + 4, ptr, len);
            // Capacity is stored shifted left one bit (low bit = seamless-slice tag).
            return .{ .bytes = @ptrFromInt(block + 4), .capacity_or_alloc_ptr = len << 1, .length = len };
        }

        /// A RocStr that takes ownership of the js_alloc block at `ptr`.
        pub fn fromParts(ptr: usize, len: usize) RocStr {
            if (len <= mem.STR_SIZE - 1) {
                const s = copied(ptr, len);
                if (ptr != 0) alloc.hostDealloc(ptr - 4);
                return s;
            }
            return .{ .bytes = @ptrFromInt(ptr), .capacity_or_alloc_ptr = len << 1, .length = len };
        }

        /// One extra reference to a string. Small strings need none.
        pub fn incref(s: RocStr) void {
            if (!s.isSmallStr()) mem.incref(@intFromPtr(s.bytes));
        }
    };
}
