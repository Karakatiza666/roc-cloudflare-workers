//! Backend `tl` of fa.zig (design e of research/alloc/foreign/README.md): a reap per task, far from v8.
//! - Each task (and the host, slot 0) bumps in its own chunks of 32 KB. A block has an 8 B header in front:
//!   its size (header included) and its slot. No page tables: a free reads only the header.
//! - A freed block goes to the free list of its slot for the largest class <= its size (LIFO, hot first).
//!   An alloc takes from the list of its class, else bumps. A realloc grows in place at the bump end.
//! - Blocks above 4 KB: a run of 4 KB pages (16 B header: length, next, prev, slot), best fit over the free runs (address order, joined).
//! - Task end: all chunks of the task go to a LIFO chunk cache (64 chunks), its large blocks to the free runs.
//! The memory of a task is its chunks and its large runs: a sum per task would read few contiguous ranges.
const std = @import("std");
const fa = @import("alloc.zig");
const mem = @import("mem.zig");

const CHUNK: usize = 32 * 1024;
const PAGE4: usize = 4096;
const HDR: usize = 8;
const LHDR: usize = 16;
const SMALL_MAX: usize = 4096; // block size with header
const CLASSES = blk: {
    var t: [32]u32 = undefined;
    for (0..16) |i| t[i] = 16 * (i + 1);
    var k = 16;
    var base = 256;
    while (base < 4096) : (base *= 2) {
        for (1..5) |j| {
            t[k] = base + base / 4 * j;
            k += 1;
        }
    }
    break :blk t;
};
const NCLS = CLASSES.len;
/// The class to allocate a block of size `s` (header included): the smallest class >= s.
inline fn classUp(s: usize) usize {
    if (s <= 256) return (s + 15) / 16 - 1;
    const lg = std.math.log2_int(usize, s - 1); // s in (2^lg, 2^(lg+1)]
    const base = @as(usize, 1) << @intCast(lg);
    const q = (s - base + base / 4 - 1) / (base / 4); // 1..4
    return 16 + (lg - 8) * 4 + q - 1;
}
/// The list for a free block of size `s`: the largest class <= s.
inline fn classDown(s: usize) usize {
    var c = classUp(s);
    if (CLASSES[c] > s) c -= 1;
    return c;
}

const Task = struct {
    owner: usize = 0,
    free: [NCLS]u32 = @splat(0),
    bump: usize = 0,
    end: usize = 0,
    chunks: usize = 0, // first chunk (word 0 of a chunk: the next chunk)
    large: usize = 0, // first large block
};
const SLOTS = 256;
var TASKS: [SLOTS]Task = @splat(.{});
var LAST_OWNER: usize = 0;
var LAST_SLOT: usize = 0;

fn slotOf(owner: usize, create: bool) usize {
    if (owner == 0) return 0;
    if (owner == LAST_OWNER) return LAST_SLOT;
    const home = 1 + (owner & 127);
    var s: usize = 0;
    if (TASKS[home].owner == owner) s = home else {
        for (1..SLOTS) |i| if (TASKS[i].owner == owner) {
            s = i;
            break;
        };
        if (s == 0) {
            if (!create) return 0;
            s = if (TASKS[home].owner == 0) home else for (1..SLOTS) |i| {
                if (TASKS[i].owner == 0) break i;
            } else @trap();
            TASKS[s] = .{ .owner = owner };
        }
    }
    LAST_OWNER = owner;
    LAST_SLOT = s;
    return s;
}

// ---------------------------------------------------------------- runs of 4 KB pages

/// Free runs, by address, joined: [len][next] in the run.
var RUNS: usize = 0;
var BRK_ALIGNED = false;
var CACHE: [64]usize = @splat(0);
var CACHED: usize = 0;

fn runAlloc(len: usize) usize {
    var best: usize = 0;
    var best_prev: usize = 0;
    var prev: usize = 0;
    var r = RUNS;
    while (r != 0) : (r = mem.rdUsize(r + 4)) {
        const l = mem.rdUsize(r);
        if (l >= len and (best == 0 or l < mem.rdUsize(best))) {
            best = r;
            best_prev = prev;
            if (l == len) break;
        }
        prev = r;
    }
    if (best != 0) {
        const l = mem.rdUsize(best);
        const next = mem.rdUsize(best + 4);
        if (l == len) {
            if (best_prev == 0) RUNS = next else mem.wrUsize(best_prev + 4, next);
            return best;
        }
        // Take the top part: the run start and its link stay.
        mem.wrUsize(best, l - len);
        return best + l - len;
    }
    if (!BRK_ALIGNED) {
        BRK_ALIGNED = true;
        const b = fa.brkMove(0);
        if (b == std.math.maxInt(usize)) return 0;
        const pad = std.mem.alignForward(usize, b, PAGE4) - b;
        if (pad != 0 and fa.brkMove(pad) == std.math.maxInt(usize)) return 0;
    }
    const p = fa.brkMove(len);
    return if (p == std.math.maxInt(usize)) 0 else p;
}

fn runFree(p: usize, len: usize) void {
    var prev: usize = 0;
    var r = RUNS;
    while (r != 0 and r < p) : (r = mem.rdUsize(r + 4)) prev = r;
    // Join with the next run, then with the previous one.
    var l = len;
    var next = r;
    if (next != 0 and p + l == next) {
        l += mem.rdUsize(next);
        next = mem.rdUsize(next + 4);
    }
    if (prev != 0 and prev + mem.rdUsize(prev) == p) {
        mem.wrUsize(prev, mem.rdUsize(prev) + l);
        mem.wrUsize(prev + 4, next);
        return;
    }
    mem.wrUsize(p, l);
    mem.wrUsize(p + 4, next);
    if (prev == 0) RUNS = p else mem.wrUsize(prev + 4, p);
}

fn chunkTake() usize {
    if (CACHED > 0) {
        CACHED -= 1;
        return CACHE[CACHED];
    }
    var c = runAlloc(CHUNK);
    if (c == 0 and drain()) c = runAlloc(CHUNK);
    return c;
}
fn chunkGive(c: usize) void {
    if (CACHED < CACHE.len) {
        CACHE[CACHED] = c;
        CACHED += 1;
    } else runFree(c, CHUNK);
}
fn drain() bool {
    if (CACHED == 0) return false;
    while (CACHED > 0) {
        CACHED -= 1;
        runFree(CACHE[CACHED], CHUNK);
    }
    return true;
}

// ---------------------------------------------------------------- blocks

inline fn hdrSize(p: usize) usize {
    return mem.rd32(p - HDR);
}
inline fn hdrSlot(p: usize) usize {
    return mem.rd32(p - HDR + 4) & 0xffff;
}
const LARGE_TAG: u32 = 0x1_0000;

pub fn alloc(owner: usize, len: usize) usize {
    const s = slotOf(owner, true);
    const t = &TASKS[s];
    const need = len + HDR;
    if (need <= SMALL_MAX) {
        const c = classUp(need);
        const f = t.free[c];
        if (f != 0) {
            t.free[c] = mem.rd32(f);
            return f;
        }
        const size = CLASSES[c];
        if (t.bump + size > t.end) {
            const ch = chunkTake();
            if (ch == 0) return 0;
            mem.wrUsize(ch, t.chunks);
            t.chunks = ch;
            t.bump = ch + 16;
            t.end = ch + CHUNK;
        }
        const b = t.bump;
        t.bump += size;
        mem.wrUsize(b, size);
        mem.wrUsize(b + 4, s);
        return b + HDR;
    }
    return largeAlloc(t, s, len);
}

fn largeAlloc(t: *Task, s: usize, len: usize) usize {
    const rl = std.mem.alignForward(usize, len + LHDR, PAGE4);
    var r = runAlloc(rl);
    if (r == 0 and drain()) r = runAlloc(rl);
    if (r == 0) return 0;
    // Header: run length, next, prev, slot with the tag (the tag word is at p - 4, as in a small header).
    mem.wrUsize(r, rl);
    mem.wrUsize(r + 4, t.large);
    mem.wrUsize(r + 8, 0);
    mem.wrUsize(r + 12, s | LARGE_TAG);
    if (t.large != 0) mem.wrUsize(t.large - LHDR + 8, r + LHDR);
    t.large = r + LHDR;
    return r + LHDR;
}

fn largeUnlink(p: usize) void {
    const t = &TASKS[hdrSlot(p)];
    const next = mem.rdUsize(p - LHDR + 4);
    const prev = mem.rdUsize(p - LHDR + 8);
    if (prev != 0) mem.wrUsize(prev - LHDR + 4, next) else t.large = next;
    if (next != 0) mem.wrUsize(next - LHDR + 8, prev);
}

pub fn free(p: usize) void {
    const tag = mem.rd32(p - HDR + 4);
    if (tag & LARGE_TAG != 0) {
        largeUnlink(p);
        runFree(p - LHDR, mem.rdUsize(p - LHDR));
        return;
    }
    const t = &TASKS[tag];
    const size = hdrSize(p);
    // The last block of the bump: give it back to the bump.
    if (p - HDR + size == t.bump) {
        t.bump = p - HDR;
        return;
    }
    const c = classDown(size);
    mem.wrUsize(p, t.free[c]);
    t.free[c] = @intCast(p);
}

pub fn usable(p: usize) usize {
    if (mem.rd32(p - HDR + 4) & LARGE_TAG != 0) return mem.rdUsize(p - LHDR) - LHDR;
    return hdrSize(p) - HDR;
}

pub fn realloc(owner: usize, p: usize, len: usize) usize {
    const room = usable(p);
    if (len <= room) return p;
    const tag = mem.rd32(p - HDR + 4);
    if (tag & LARGE_TAG == 0) {
        // At the bump end of its task: grow in place.
        const t = &TASKS[tag];
        const size = hdrSize(p);
        const want = std.mem.alignForward(usize, len + HDR, 16);
        if (p - HDR + size == t.bump and want <= SMALL_MAX and p - HDR + want <= t.end) {
            t.bump = p - HDR + want;
            mem.wrUsize(p - HDR, want);
            return p;
        }
    }
    // Move: 1.5x room for a block that grows again.
    const q = alloc(owner, @max(len, room + room / 2));
    if (q == 0) return 0;
    mem.copyBytes(q, p, room);
    free(p);
    return q;
}

/// The task ended: its chunks to the cache, its large blocks to the free runs.
pub fn taskEnd(owner: usize) void {
    const s = slotOf(owner, false);
    if (s == 0) return;
    const t = &TASKS[s];
    var c = t.chunks;
    while (c != 0) {
        const next = mem.rdUsize(c);
        chunkGive(c);
        c = next;
    }
    var l = t.large;
    while (l != 0) {
        const next = mem.rdUsize(l - LHDR + 4);
        runFree(l - LHDR, mem.rdUsize(l - LHDR));
        l = next;
    }
    t.* = .{};
    LAST_OWNER = 0;
}
