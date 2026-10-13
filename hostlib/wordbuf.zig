//! Growable u32 word buffers: the command buffer, the effect queue, the log queue.

const std = @import("std");
const mem = @import("mem.zig");
const alloc = @import("alloc.zig");
const options = @import("build_options");

// `-Dsmall-buffers` shrinks the initial capacities so every render grows them.
pub const CMDS_INITIAL: usize = if (options.small_buffers) 8 else 4096;
pub const EFFECTS_INITIAL: usize = if (options.small_buffers) 8 else 2048;
pub const LOG_INITIAL: usize = if (options.small_buffers) 4 else 512;

pub const WordBuf = struct {
    ptr: usize = 0,
    cap: usize = 0,
    len: usize = 0,

    /// Append a word, doubling the buffer on demand.
    pub fn push(self: *WordBuf, initial_cap: usize, word: u32) void {
        if (self.len == self.cap) {
            const new_cap = if (self.cap == 0) initial_cap else self.cap * 2;
            self.ptr = if (self.ptr == 0) alloc.allocOrTrap(new_cap * 4, 4) else alloc.reallocOrTrap(self.ptr, new_cap * 4, 4);
            self.cap = new_cap;
        }
        mem.wr32(self.ptr + self.len * 4, word);
        self.len += 1;
    }

    pub inline fn set(self: *WordBuf, idx: usize, word: u32) void {
        mem.wr32(self.ptr + idx * 4, word);
    }

    /// Append (ptr, len) of a host-owned copy of the bytes. Empty bytes are (0, 0).
    pub fn pushCopy(self: *WordBuf, initial_cap: usize, ptr: usize, len: usize) void {
        if (len == 0) {
            self.push(initial_cap, 0);
            self.push(initial_cap, 0);
            return;
        }
        const copy = alloc.allocOrTrap(len, 1);
        mem.copyBytes(copy, ptr, len);
        self.push(initial_cap, @intCast(copy));
        self.push(initial_cap, @intCast(len));
    }

    /// Append the bytes inline: the length, then the bytes in little-endian words.
    pub fn pushInline(self: *WordBuf, initial_cap: usize, p: usize, l: usize) void {
        self.push(initial_cap, @intCast(l));
        const words = (l + 3) / 4;
        for (0..words) |w| {
            var word: u32 = 0;
            for (0..4) |b| {
                const idx = w * 4 + b;
                if (idx < l) word |= @as(u32, mem.rd8(p + idx)) << @intCast(8 * b);
            }
            self.push(initial_cap, word);
        }
    }
};
