# Allocator research

Goal: one wasm instance per isolate (variant B), with a cheap sum of each task's memory at each wait (PLAN.md problem 12). A task's memory must sit in few contiguous places, and freed memory must be used again.

The versions, the harness and the scripts stay in the repo until talon is implemented. Then the allocator gets a new benchmark with talon's real requests (record its traces with `TRACE=1`, replay them, and run `scripts/all.sh`).

Contents:
1. Versions: a summary table.
2. Build and run.
3. Benchmarks: one table for each topic, with all versions in the columns.
4. Settings tried: one table for the switches of all versions.
5. The allocators in order: what each one changed, and why.

## Versions

| Version | File | Small blocks | Large blocks | Memory back | Status |
|---|---|---|---|---|---|
| v0 | `versions/v0.zig` | Global size classes, one free list each | Own span, never joined or split | Never | Old platform allocator |
| v1 | `versions/v1.zig` | Bump in task chunks of 16 KB, free lists per task | TLSF in the task's chunks | At task end | Dropped: memory |
| v2 | `versions/v2.zig` | One class per 4 KB page, per task | TLSF per task over runs of at least 64 KB | Empty page at once | Dropped: memory |
| v3 | `versions/v3.zig` | As v2 | A buddy block per block, tail pages back | At once | Dropped: memory, `grow` out of memory |
| v4 | (deleted) | smalloc port: power-of-2 slots | Slots stay in their class | | Dropped: 115 MB at 2,000 items |
| v5 | `versions/v5.zig` | As v2, at the lowest free unit | TLSF per task in pages (4 to 256 KB); own run above, from the top | At once | Dropped: CPU |
| v6 | `versions/v6.zig` | As v5, no headers | Own run, best fit from the top, lists by length | Keeps one empty page per class | Replaced by v7 |
| v6_aos | `versions/v6_aos.zig` | v6 with one record per unit | | | Dropped: no change |
| v7 | `versions/v7.zig` | As v6, empty page at once to a reserve of 256 pages | As v6 | At once | Chosen (PLAN.md step 6e) |

## Build and run

```
research/alloc/build.sh v0 v1 v2 v3 v5 v6 v7   # apps: out/app_<v>.wasm and out/app_v_<v>.wasm
replay/build.sh v0 v1 v2 v3 v5 v6 v7           # replay modules: out/replay_<v>.wasm
cd research/alloc
scripts/all.sh                                 # all benchmarks below, all versions, into out/all/
node .work/bench/node-test.mjs out/app_v7.wasm
node scripts/replay.mjs 2000_6 7 v6 v7 v6:set_place=0          # one trace; a version can carry setters
node scripts/ab.mjs 3000 v0 v7                                 # full app, variant A and B; env CONC, ITEMS
ID0=1 node scripts/peak.mjs v7                                 # fresh process: memory, peak of pages, live peak
node scripts/strloop.mjs v7 '2 0 20000' '2 0 80000'
SUM=2 node scripts/wild.mjs v7 256 20000 0.005 20
node scripts/dfree.mjs v7; node scripts/adopt.mjs v7           # double free, adopt after a trap
node scripts/fmark.mjs v7; node scripts/reserve.mjs v7         # live block with the mark, reserve at the memory cap
TRACE=1 ./build.sh v5 && node scripts/trace.mjs 2000 6 && node scripts/trace.mjs 200 40
node scripts/synth.mjs med; node scripts/synth.mjs mix; node scripts/synth.mjs grow
node scripts/tune5.mjs 4 0 2000 0                              # v5 page sizes
```

`build.sh` copies the repo to `.work/`, puts `harness/` over it (a host with sum modes and wild writes, platform exports, `core.js`, the string-loop app), and builds each version as `hostlib/alloc.zig`. `probe.py` adds peak probes and export stubs.

## Benchmarks

Measured 2026-10-14, Node 26.7, one core, `scripts/all.sh`. The raw output is in `out/all/`. The replay and full-app numbers are from a second pass (17:31 to 18:06), with nothing else on the machine. The fresh-process, string-loop and wild-write numbers are from the first pass (15:05 to 16:08).

### Tests

| Test | What runs | Noise | Script |
|---|---|---|---|
| Full app | `bench/app.roc`: each request makes a list of 200 or 2,000 items and a JSON body, with waits that resolve at once. Median of 3 runs of 3,000 requests. | About 3 % | `ab.mjs` |
| Fresh process | Full app, 50 batches of 64 requests at 2,000 items, in a new process, for 4 first request ids (the ids change the sizes) | None: same ids, same result | `peak.mjs` |
| Replay | A recorded trace of allocator calls, with no app code. `2000_6`: 384 requests at 2,000 items, 6 at once (8.6 M calls, 768 waits). `200_40`: 2,560 requests at 200 items, 40 at once (6.4 M calls, 5,120 waits). Median of 7. | About 1 % | `replay.mjs` |
| Synthetic | Traces with sizes the app does not make, 64 tasks, 160,000 calls, 4,000 waits. `med`: 2 to 16 KB. `mix`: 80 % 16 to 512 B, 20 % 1 to 64 KB. `grow`: one buffer per task that grows 1.5x to 1 MB. | About 1 % | `synth.mjs`, `replay.mjs` |
| String loop | Bug B5: a string that grows by realloc, 20,000 or 80,000 steps | None | `strloop.mjs` |
| Wild writes | 20,000 requests, 64 at once, I/O of 20 ms. 0.5 % of requests write random words, then trap. Count of wrong bodies with status 200. | Counts change between runs | `wild.mjs` |

What the app does (trace of one 2,000-item request): 8,100 small allocs, 6,000 small reallocs, one 144 KB list, one JSON string that realloc grows 1.5x 13 times from 2.3 KB to 728 KB, and a 22 KB saved stack at each wait. Large blocks are about 13 of 22,000 calls. So the small path and the copies of the growing string set the CPU.

Sum modes: 0 = no sums. 1 = a sum at each wait, checked only after an alarm. 2 = also a check at each resume after other tasks ran (the plan's default). Variant A = a new instance for each request. Variant B = one shared instance.

### Memory, MB

Memory: the size of wasm memory at the end. For variant A: the total of the instances that are live at once. Live peak: the most bytes that the program holds at once.

| Test | Live peak | v0 | v1 | v2 | v3 | v5 | v6 | v7 |
|---|---|---|---|---|---|---|---|---|
| Fresh process, first id 1 | 48.8 to 49.4 | 164.4 | 158.5 | 155.8 | 68.0 | 54.8 | 53.6 | 52.9 |
| Fresh process, first id 300 | 48.4 to 49.2 | 119.1 | 151.6 | 107.4 | 67.0 | 54.4 | 53.1 | 52.4 |
| Fresh process, first id 100,000 | 49.2 to 50.4 | 74.9 | 103.6 | 59.4 | 68.0 | 55.9 | 54.1 | 53.0 |
| Fresh process, first id 1,000,000 | 34.1 to 35.1 | 51.4 | 98.4 | 48.7 | 67.0 | 41.6 | 38.9 | 37.5 |
| Fresh process, id 1: peak of pages in use | | | 97.5 | 54.4 | 51.9 | 51.5 | 51.3 | 49.5 |
| B, 64 at once, 200 items | | 14.4 | 14.7 | 13.8 | 11.7 | 10.6 | 9.6 | 7.8 |
| B, 16 at once, 2,000 items | | 51.2 | 46.8 | 49.3 | 19.0 | 16.9 | 15.4 | 15.3 |
| B, 16 at once, 200 items | | 5.3 | 4.9 | 5.7 | 4.4 | 4.5 | 4.1 | 3.7 |
| B, 1 at once, 2,000 items | | 8.7 | 5.7 | 7.7 | 5.0 | 5.3 | 3.6 | 3.6 |
| B, 1 at once, 200 items | | 1.9 | 1.9 | 3.1 | 2.2 | 2.6 | 2.4 | 2.4 |
| A, 64 at once, 2,000 items | | 244 | 268 | 348 | 320 | 288 | 232 | 232 |
| A, 64 at once, 200 items | | 100 | 120 | 200 | 136 | 164 | 152 | 152 |
| A, 16 at once, 2,000 items | | 61 | 67 | 87 | 80 | 72 | 58 | 58 |
| A, 1 at once, 200 items | | 1.6 | 1.9 | 3.1 | 2.1 | 2.6 | 2.4 | 2.4 |
| Replay `2000_6` | | 116.1 | 108.9 | 104.9 | 66.3 | 52.4 | 50.3 | 49.3 |
| Replay `200_40` | | 13.1 | 13.1 | 10.9 | 9.8 | 8.3 | 7.4 | 5.6 |
| Synthetic `med` | 14.6 | 63.3 | 24.9 | 23.3 | 20.6 | 19.5 | 18.8 | 18.6 |
| Synthetic `mix` | 8.1 | 40.8 | 18.6 | 20.8 | 17.1 | 12.6 | 12.3 | 11.4 |
| Synthetic `grow` | 64.4 | 212.2 | 133.0 | 197.6 | out of memory | 87.6 | 71.8 | 70.8 |
| String loop, 20,000 steps | | 1,449.8 | 3.0 | 5.8 | 2.8 | 3.0 | 2.8 | 2.7 |
| String loop, 80,000 steps | | out of memory | 10.5 | 34.5 | 5.0 | 5.6 | 5.4 | 5.3 |

The B rows at 64 at once and 2,000 items are the "fresh process, first id 1" row. In A, v6 and v7 use more memory than v0 for small requests: each instance has the unit tables (about 0.9 MB of `.bss`). In B there is one copy.

### CPU: full app, µs per request

| Requests at once, items | Mode | v0 | v1 | v2 | v3 | v5 | v6 | v7 |
|---|---|---|---|---|---|---|---|---|
| 1, 200 | A | 347 | 379 | 389 | 363 | 380 | 330 | 332 |
| | B | 198 | 217 | 202 | 202 | 211 | 204 | 203 |
| | B sum 1 | 210 | 205 | 208 | 205 | 212 | 208 | 206 |
| | B sum 2 | 205 | 204 | 210 | 210 | 210 | 208 | 204 |
| 16, 200 | A | 341 | 338 | 380 | 360 | 449 | 357 | 360 |
| | B | 201 | 201 | 214 | 222 | 231 | 215 | 219 |
| | B sum 1 | 218 | 206 | 217 | 222 | 234 | 219 | 222 |
| | B sum 2 | 231 | 215 | 221 | 226 | 227 | 222 | 229 |
| 64, 200 | A | 386 | 364 | 404 | 361 | 397 | 361 | 377 |
| | B | 218 | 211 | 222 | 215 | 223 | 221 | 214 |
| | B sum 1 | 251 | 222 | 230 | 220 | 226 | 216 | 216 |
| | B sum 2 | 285 | 235 | 243 | 227 | 228 | 220 | 221 |
| 1, 2,000 | A | 2,476 | 2,630 | 2,651 | 2,542 | 2,565 | 2,351 | 2,350 |
| | B | 1,852 | 1,885 | 1,959 | 1,943 | 1,935 | 1,930 | 1,921 |
| | B sum 1 | 2,026 | 1,924 | 1,972 | 1,960 | 1,963 | 1,964 | 1,949 |
| | B sum 2 | 1,985 | 1,926 | 1,972 | 1,952 | 1,969 | 1,958 | 1,942 |
| 16, 2,000 | A | 2,487 | 2,507 | 2,642 | 2,621 | 2,583 | 2,374 | 2,411 |
| | B | 1,888 | 1,909 | 1,974 | 1,950 | 1,983 | 2,044 | 1,982 |
| | B sum 1 | 2,031 | 2,002 | 1,998 | 2,003 | 2,031 | 2,054 | 2,080 |
| | B sum 2 | 2,156 | 2,101 | 2,022 | 2,028 | 2,081 | 2,131 | 2,100 |
| 64, 2,000 | A | 2,722 | 2,625 | 2,698 | 2,609 | 2,775 | 2,403 | 2,468 |
| | B | 2,053 | 1,959 | 2,021 | 1,999 | 2,021 | 1,968 | 1,995 |
| | B sum 1 | 2,120 | 2,025 | 2,055 | 2,031 | 2,060 | 2,047 | 2,053 |
| | B sum 2 | 2,223 | 2,084 | 2,059 | 2,087 | 2,089 | 2,132 | 2,110 |

All runs: 0 wrong bodies. Most allocator differences in this table are inside the 3 % noise. Use the replay for the allocator CPU.

| v7: B sum 2 against A | CPU | Memory |
|---|---|---|
| 64 at once, 200 items | -41 % (221 against 377 µs) | 19x less (7.8 against 152 MB) |
| 64 at once, 2,000 items | -15 % (2,110 against 2,468 µs) | 4.4x less (52.9 against 232 MB). A is above the 128 MB isolate limit. |
| 1 at once, 2,000 items | -17 % (1,942 against 2,350 µs) | Same (3.6 MB) |

A pays for a new instance on each request (instantiate, `init`, cold code, and memory that grows from the start): about 130 to 160 µs at 200 items and 400 to 500 µs at 2,000 items. The sums cost v7 in B at 64 at once: +1 % (sum 1) and +3 % (sum 2) at 200 items, +3 % and +6 % at 2,000 items. v0 must walk the heap for each sum: +31 % with sum 2 at 64 at once and 200 items.

### CPU: replay, ms per trace

| Trace | Sums | v0 | v1 | v2 | v3 | v5 | v6 | v7 |
|---|---|---|---|---|---|---|---|---|
| `2000_6` | none | 57.2 | 85.3 | 93.4 | 84.3 | 106.1 | 73.3 | 74.6 |
| | sum 1 | 105.3 | 121.8 | 110.1 | 103.3 | 124.8 | 89.3 | 88.7 |
| | sum 2 | 158.1 | 152.3 | 122.2 | 115.6 | 136.6 | 101.3 | 104.7 |
| `200_40` | none | 29.4 | 50.6 | 62.3 | 56.8 | 74.2 | 55.8 | 53.9 |
| | sum 1 | 106.0 | 74.8 | 78.1 | 73.3 | 81.4 | 72.4 | 65.4 |
| | sum 2 | 181.6 | 94.9 | 92.6 | 76.6 | 89.1 | 81.2 | 70.5 |
| `med` | none | 16.3 | 18.6 | 18.7 | 21.1 | 162.0 | 12.2 | 11.3 |
| | sum 2 | 251.4 | 70.2 | 70.0 | 72.8 | 222.6 | 60.6 | 57.2 |
| `mix` | none | 10.9 | 8.2 | 15.6 | 9.9 | 29.6 | 7.0 | 7.9 |
| | sum 2 | 138.7 | 33.2 | 41.1 | 26.5 | 48.0 | 22.2 | 21.0 |
| `grow` | none | 42.1 | 34.1 | 51.2 | out of memory | 36.5 | 30.4 | 30.1 |
| | sum 2 | 253.3 | 58.4 | 76.4 | | 58.9 | 51.4 | 50.2 |

In sum mode 2, 0 sums differed in all traces. v0 has the fastest small path (one global free list per class), but its sums walk the whole heap. The v7 sums cost 30 ms per 384 requests at 2,000 items (about 78 µs per request), and 17 ms per 2,560 requests at 200 items (about 7 µs per request).

### Sums, copies and code size

| Measure | v0 | v1 | v2 | v3 | v5 | v6 | v7 |
|---|---|---|---|---|---|---|---|
| KB summed per wait, `2000_6` | 1,357 (heap walk) | 1,532 | 808 | 764 | 764 | 759 | 752 |
| KB summed per wait, `200_40` | 111 (heap walk) | 206 | 144 | 92 | 92 | 87 | 79 |
| MB copied by realloc, `2000_6` | 410 | 444 | 444 | 274 | 424 | 132 | 208 |
| MB copied by realloc, `200_40` | 246 | 203 | 203 | 115 | 330 | 101 | 108 |
| MB copied by realloc, `grow` | 155 | 356 | 356 | | 301 | 362 | 367 |
| Reallocs that grow in place, `2000_6` | | | | | | 4,185 | 3,518 |
| Lines of code (no blanks or comments) | 289 | 587 | 642 | 611 | 824 | 696 | 748 |

v6 and v7 line counts include the research switches. PLAN.md step 6e removes them from the port.

### Wrong bodies after wild writes

Wrong bodies with status 200 in 20,000 requests:

| Words written | Sum mode | v0 | v1 | v2 | v3 | v5 | v6 | v7 |
|---|---|---|---|---|---|---|---|---|
| 16 | 0 | 39 | 5 | 4 | 5 | 9 | 5 | 17 |
| 256 | 0 | 358 | 105 | 68 | 102 | 86 | 87 | 273 |
| 4,096 | 0 | 239 | 589 | 523 | 416 | 620 | 514 | 319 |
| 16, 256, 4,096 | 1 or 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

The counts with no sums change between runs (an earlier run gave v1 69 and v3 92 at 256 words). The result that matters: with sums, 0 for all versions.

### Double frees

| | v0 to v5 | v6 | v7 |
|---|---|---|---|
| Check | Seal word in a 16 B block header | None | Free mark in word 0 of a freed small block, plus a walk of the page's free list on a match |
| Miss | | All | A double free after the page went back (`dealloc_miss`) |
| Test | | | `dfree.mjs`: 3 of 3 caught; with the check removed, two live blocks get the same address |

## Settings tried

Each row is a switch in one version. The numbers are from the run of that change (replay `2000_6` unless the row names another test). Compare a row only with the base row of its version.

| Version | Setting | Memory, MB | CPU | MB copied | Result |
|---|---|---|---|---|---|
| v5 | Base: small pages of 4 KB, large pages of max(16 KB, block) | Full app (`tune5.mjs`, 64 at once): 55.1; 200 items 10.4 | | | Kept |
| v5 | Page sizes of the first design (small 4 to 32 KB, large 128 KB to 1 MB, each next page 2x) | 75.2, 15.9 (200 items) | | | Worse. Each doubling of page sizes was worse in every test. |
| v5 | Pages of 32 KB | `med` 20.8, `mix` 13.6, `grow` 86.6 | `med` 278 ns per call against 1,088 | | Faster on `med`, more memory |
| v5 | No TLSF (`set_large_max(4096)`) | 52.5 (same) | Same; `med` 1,689 ns per call | | Led to v6 |
| v5 | Highest fit (`PLACE=0`) | Up to 71.6 for some first ids | | | Worse |
| v6 | Base: keep one empty page per class (Hoard), moved block to the low end of a 2x run | 50.3 | 72.5 ms | 132 | |
| v6 | Give an empty page back at once (`set_keep_empty(0)`) | 48.6 (-1.7); 200 items -1.8 | +29 %, 16x the page takes | 131 | Slower: the pool work (bitmap, joins), not the page setup |
| v6 | Keep empty pages to task end (`set_keep_empty(2)`) | 83 | | | Worse |
| v6 | Moved block not placed (`set_place(0)`) | `grow` 87.9 against 71.8 | 84 against 74 ms | 371 | Worse |
| v6 | Moved block to a 4x run, or to the largest run (`set_place(255)`) | Same as 2x | | | No gain |
| v6 | No growth in place at the top of the pool (`set_grow_at_top(0)`) | +0.5 | +2 % | | Growth at the top kept |
| v6 | One 32 B record per unit (v6_aos) | Same | Same | | Arrays kept |
| v6 | Page back at once, to a reserve with no cap (`set_page_cache(1)`) | 49.3; 200 items 5.6 | 76.6 ms | 217 | Led to v7 |
| v6 | Same, reserve of at most 256 pages (`set_cache_max(256)`) | 49.3; 200 items 5.6 | 75.2 ms | 208 | This is v7 |
| v6 | Reserve, and keep one empty page per class | 61.1; 200 items 7.6 | 75.3 ms | 240 | Worse |
| v7 | Base | 49.3 | | 208 | |
| v7 | Give the reserve back before memory grows (`set_cache_drain(1)`) | 52.4 | | 232 | Worse: the drained pages change where blocks go. Default 2: drain only when memory cannot grow. |
| v7 | Take reserved pages after a large block that grows in place | 49.3 | | 215 | Worse |
| v7 | Moved block to the largest free run (`set_place=255`) | 49.4; `med` +1.7, `mix` +1.4 | | 133 | Copies as v6, more memory |
| v7 | Largest run only for moved blocks of 64 KB or more | 49.4 | | 200 | Small gain |
| v7 | Same, from 16 KB | 49.4; `mix` +1.0 | | 184; 200 items +12 | Not kept |

## The allocators, in order

### v0: the old platform allocator

`hostlib/alloc.zig` at commit 30cc1ca, with `taskEnd` (no-op) and a sum by heap walk added for the harness. One shared heap, with a free list for each size class. A large block gets its own span, and spans are never joined or split.

- Fast small path: the best replay CPU without sums.
- Bug B5: a string that grows by realloc never reuses its old spans (1,450 MB at 20,000 steps, out of memory at 80,000).
- The blocks of all tasks are mixed. So a task sum must walk the whole heap, and the sum costs the most of all versions.

### v1: an arena per task

An nginx-style pool for each task: 16 KB chunks from a shared pool, bump allocation, free lists for each task, and TLSF for large blocks in the task's own chunks. All chunks go back at task end.

- Fixes B5 (3.0 MB at 20,000 steps), and a task's memory is its own chunks.
- A task keeps all its chunks until it ends: 159 MB in a fresh process, which is above the 128 MB limit.

### v2: pages per task, empty pages back

Small blocks: one size class per 4 KB page (as mimalloc), and an empty page goes back to the pool. Large blocks: TLSF for each task, over runs of at least 64 KB, with joins and splits. Pool: first fit over a bitmap of 4 KB chunks.

- Memory goes back while the task runs.
- The 64 KB runs of TLSF fragment the pool: still 156 MB in a fresh process, and 34.5 MB on the string loop.

### v3: a buddy pool

Small blocks as v2. Pool: a binary buddy over 4 KB pages, lowest address first. A large block gets a buddy block, and the pages after its end go back at once. The cap is 128 MB, so page indexes are u16.

- The first version under the limit: 68 MB, the same for all first ids.
- Buddy rounding wastes memory, and the `grow` trace runs out of memory.

### v4: a smalloc port (deleted)

A port of smalloc (zooko): power-of-2 slots, no headers, and large slots stay in their class. 115 MB on the 2,000-item test, so it was dropped.

### v5: small low, large high

Small blocks as v2, in 4 KB pages at the lowest free unit. Large blocks (4 to 256 KB): TLSF for each task, in pages of max(16 KB, block), best fit from the top. Huge blocks (above 256 KB): an own run, best fit from the top. A free bitmap of 4 KB units, 128 MB cap.

- Small pages at the bottom and large runs at the top keep the pool in one piece: 54.8 MB.
- The best-fit scan (`bestHigh`) reads the bitmap of the whole heap for each large block: about 1 µs per call on `med`, and the worst replay CPU.

### v6: no TLSF, no headers, an index of free runs

v5 without TLSF and without block headers. Small blocks (up to 2 KB): one class per 4 KB page, per task, at the lowest free unit. The current page is the head of the class list, and a full page leaves the list at the next alloc. Larger blocks: an own run of units, best fit, at the top. Free runs: a bitmap plus lists by length (as TLSF, O(1) fit). A block that realloc moves goes to the low end of a run of 2x its size, so the next realloc grows in place. JS blocks sit in their own pages, with an owner word.

- 31 % less allocator CPU than v5, and 3.2x fewer bytes copied (132 against 424 MB).
- Lost: the seal word that caught double frees.

### v6_aos

v6 with one 32 B record per unit in place of one array per field. No change in CPU, so v6 keeps the arrays.

### v7: pages back at once, a reserve for small pages, a free mark

v6, plus:
- An empty small page goes back at once, to a stack of at most 256 pages (1 MB) that only small pages use. A push or a pop, with no bitmap work and no joins. When memory cannot grow, the reserve goes back to the pool and the alloc tries again.
- A freed small block holds a free mark in word 0, so a second free is caught (`double_frees`). The host sets a random mark for each instance (`set_free_mark`), as the glibc tcache key.
- No live count for each task.

Result: the least memory in all replays, in the fresh-process tests, and in B with 16 or 64 tasks at once. The same CPU as v6. It copies more than v6 (208 against 132 MB). Cause: a moved block goes to a run of 2x its size. The reserve holds units that would join those runs, so a 2x run fills sooner and the next growth copies again (3,518 grows in place against 4,185). The fixes tried are in "Settings tried".

Fix in v6 and v7 (found with v7): the JS task record had slot 0, so JS pages were marked as host pages. `adopt` then never wrote the owner word, and a free of a JS block went to the host's page lists. Test: `scripts/adopt.mjs` (it fails without the fix).

Risks found after v7, and their fixes:

| Risk | Fix | Test (it fails without the fix) | Cost |
|---|---|---|---|
| A live block that starts with the mark and a valid link is not freed: a leak until its task ends | On a match, walk the page's free list (at most one step per slot). If the block is not on the list, free it as usual (`mark_false` counts it). The random mark makes a match rare. | `fmark.mjs`: without the walk, the block is not used again (3 of 3 sizes) | None in the replay: the walk runs only on a match |
| Large blocks cannot use the reserve: out of memory with up to 1 MB of free pages | `set_cache_drain(2)` (default): give the reserve back to the pool when memory cannot grow, then try again | `reserve.mjs`: memory full to the 128 MB cap; a 1 MB block fails with drain 0 | None: no trace reaches the cap |
| More copies than v6 | Not fixed (see above) | | About 0.2 MB more copies per request, no CPU change |

Prior art for the parts of v7:

| v7 part | Similar design |
|---|---|
| One size class per 4 KB page, no block headers | mimalloc (free list per page); Go `mspan` |
| Slot index by a multiply (RECIP) | Go `mspan.divMul`; Linux SLAB `reciprocal_divide` |
| Small pages low, large runs high | drm_mm two-ended allocation (GPU memory, 2014: up to 20 % less eviction); a Java heap patent (US9037830B2) |
| Free runs in lists by length, boundary tags, joins | TLSF (Masmano 2008), over 4 KB units |
| Bitmap for the lowest free unit | Go `pageAlloc` (address-ordered first fit with a radix tree of summaries) |
| Keep the only page with room (v6) | mimalloc `_mi_page_retire` |
| Blocks per task, freed one by one or all at task end | Reaps (Berger, Zorn, McKinley, OOPSLA 2002) |
| Free mark plus a list check for a double free | glibc tcache key (2.29 and later) |

Not found elsewhere: sums for each task at each wait, and a page reserve that only small pages can use.

Also checked: `nilslice/workers-zig` (a community Zig library for Workers, not from Cloudflare). Its `env.allocator` is `std.heap.ArenaAllocator` over `std.heap.wasm_allocator`, made for each handler call, with no free and no reuse in a request. That is v1 without free lists, so it has the B5 problem. Its global `workers.allocator` has no task owner, so a sum for each task is not possible.
