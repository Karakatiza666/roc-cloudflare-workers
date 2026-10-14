const a = @import("alloc_x.zig");
export fn h_alloc(len: usize, owner: usize) usize {
    a.OWNER = owner;
    return a.hostAlloc(len);
}
export fn h_realloc(p: usize, len: usize, owner: usize) usize {
    a.OWNER = owner;
    return a.hostRealloc(p, len);
}
export fn h_free(p: usize) void {
    a.hostDealloc(p);
}
export fn h_free_owner(o: usize) usize {
    return a.freeOwner(o);
}
export fn h_set_step(pages: usize) void {
    a.STEP_PAGES = pages;
}
export fn h_live() usize { return a.LIVE_BYTES; }
export fn h_next() usize { return a.NEXT; }
export fn h_end() usize { return a.END; }
export fn h_start() usize { return a.START; }
export fn h_grows() usize { return a.GROWS; }
export fn h_walks() usize { return a.WALKS; }
export fn h_walk_gain() usize { return a.WALK_GAIN; }
export fn h_splits() usize { return a.SPLITS; }
export fn h_joins() usize { return a.JOINS; }
export fn h_tops() usize { return a.TOP_LOWERS; }
/// alloc_bench of host/host.zig: n rounds of k allocs then k frees.
export fn h_bench(n: u32, k: u32, size: usize) u32 {
    var ptrs: [256]usize = undefined;
    var sum: u32 = 0;
    for (0..n) |_| {
        for (0..k) |i| ptrs[i] = a.hostAlloc(size);
        for (0..k) |i| {
            sum +%= @truncate(ptrs[i]);
            a.hostDealloc(ptrs[i]);
        }
    }
    return sum;
}
/// Fragmented bench: frees in a shuffled order (xorshift), so joins and lists see mixed neighbors.
export fn h_bench_mixed(n: u32, k: u32, seed0: u32) u32 {
    var ptrs: [256]usize = undefined;
    var seed: u32 = seed0;
    var sum: u32 = 0;
    for (0..n) |_| {
        for (0..k) |i| {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            const size: usize = 8 + (seed % 2000);
            ptrs[i] = a.hostAlloc(size);
        }
        var i: usize = k;
        while (i > 0) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            const j = seed % i;
            i -= 1;
            sum +%= @truncate(ptrs[j]);
            a.hostDealloc(ptrs[j]);
            ptrs[j] = ptrs[i];
        }
    }
    return sum;
}
export fn h_walk() void {
    a.reclaimWalk();
}
