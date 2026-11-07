# Allocator research

Goal: one wasm instance per isolate (variant B), with a cheap sum of each task's memory at each wait (PLAN.md problem 12). A task's memory must sit in few contiguous places, and freed memory must be used again.

The versions, the harness and the scripts stay in the repo until talon is implemented. Then the allocator gets a new benchmark with talon's real requests (record its traces with `TRACE=1`, replay them, and run `scripts/all.sh`).

Contents:
1. Versions: a summary table.
2. Build and run.
3. Benchmarks: one table for each topic, with all versions in the columns.
4. Settings tried: one table for the switches of all versions.
5. The allocators in order: what each one changed, and why.
6. Real apps: stats per request and traces of the platform (the bench variant of an external app).

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
| port | `hostlib/alloc.zig` | v7 without the switches, plus `mayFree`, the live peak, step counts, sums of adopted JS blocks, the counters of the stats header. Since 2026-11-07: the short paths of v8 | As v7 | As v7 | In the platform |
| v8 | `versions/v8.zig` | As v7, short paths: one read of each table per call | As v7 | As v7 | In the port (2026-11-07) |
| v9, v9f, v9b1, v9b2 | `versions/v9*.zig` | The port at 6c580d5 (v9), and one change each (no zero write; 8 classes; 21 classes) | As the port | As the port | Tried on the full registry: no gain (2026-11-07) |
| foreign | `foreign/` | Other designs behind an adapter: bump, Zig WasmAllocator, dlmalloc, emmalloc, mimalloc, a reap per task (`foreign/README.md`) | | | Measured on the total registry CPU, sums off (2026-11-07): ceiling -1.7 % instructions, no cache effect; dlmalloc 35 % less memory |
| null | `versions/null.zig` | Not an allocator: one static block, no frees | | | Tool: the replay cost with no allocator |

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
node scripts/synth.mjs tiny 64 8000                            # short tasks: the fixed cost of a request
node scripts/micro.mjs                                         # micro traces: af, lifo, chain, task
replay/build.sh port null                                      # the platform allocator (stubs: replay/cpu.zig, replay/native/), the replay with no allocator
node scripts/pstat.mjs 2000_6 4 3 0,2 null v7 port v8          # perf stat: M cycles and M instructions per trace (noisy machine: use instructions)
node scripts/rcmp.mjs 2000_6 9 0,2 null v7 v8                  # wall time, versions interleaved, median and p25 to p75
node scripts/tstats.mjs 2000_6 200_40                          # calls of a trace by kind
replay/profbuild.sh v7 && node --no-wasm-inlining scripts/prof.mjs 2000_6 v7_prof 2   # self time per function
node scripts/replay.mjs 2000_6 7 v7:set_no_copy=1              # the replay with no realloc copy (its time = the copy time)
node scripts/tune5.mjs 4 0 2000 0                              # v5 page sizes
```

`build.sh` copies the repo to `.work/`, puts `harness/` over it (a host with sum modes and wild writes, platform exports, `core.js`, the string-loop app), and builds each version as `hostlib/alloc.zig`. `probe.py` adds peak probes and export stubs.

Harness fix (2026-11-07). The platform removed `Wait.wait!` (PLAN.md 8a), so `build.sh` failed for all versions. Now the harness has its own platform: `harness/bench/platform/main.roc` and `Wait.roc`, and `harness/bench/app.roc` (both copied from commit d8d9e96). The glue comes from that platform. `harness/build.zig` adds the build option `trace` and the `zstd_dec` module (as the platform `build.zig`). `probe.py` adds shims for the current hostlib (`allocHostOrTrap`, `reallocHostOrTrap`: the call as owner 0; `hostBlockOk`: yes) to the versions that do not have them. The `port` build takes the working copy of `hostlib/alloc.zig`.

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

| Test | Live peak | v0 | v1 | v2 | v3 | v5 | v6 | v7 | v7, 2026-11-07 | port | v8 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Fresh process, first id 1 | 48.8 to 49.4 | 164.4 | 158.5 | 155.8 | 68.0 | 54.8 | 53.6 | 52.9 | 52.8 | 52.8 | 52.8 |
| Fresh process, first id 300 | 48.4 to 49.2 | 119.1 | 151.6 | 107.4 | 67.0 | 54.4 | 53.1 | 52.4 | 55.3 | 55.3 | 55.3 |
| Fresh process, first id 100,000 | 49.2 to 50.4 | 74.9 | 103.6 | 59.4 | 68.0 | 55.9 | 54.1 | 53.0 | 52.8 | 52.8 | 52.8 |
| Fresh process, first id 1,000,000 | 34.1 to 35.1 | 51.4 | 98.4 | 48.7 | 67.0 | 41.6 | 38.9 | 37.5 | 37.8 | 37.7 | 37.8 |
| Fresh process, id 1: peak of pages in use | | | 97.5 | 54.4 | 51.9 | 51.5 | 51.3 | 49.5 | 49.5 | not probed | not probed |
| B, 64 at once, 200 items | | 14.4 | 14.7 | 13.8 | 11.7 | 10.6 | 9.6 | 7.8 | 8.1 | 8.1 | 8.1 |
| B, 16 at once, 2,000 items | | 51.2 | 46.8 | 49.3 | 19.0 | 16.9 | 15.4 | 15.3 | 20.7 | 20.6 | 20.7 |
| B, 16 at once, 200 items | | 5.3 | 4.9 | 5.7 | 4.4 | 4.5 | 4.1 | 3.7 | 3.8 | 3.7 | 3.8 |
| B, 1 at once, 2,000 items | | 8.7 | 5.7 | 7.7 | 5.0 | 5.3 | 3.6 | 3.6 | 3.6 | 3.6 | 3.6 |
| B, 1 at once, 200 items | | 1.9 | 1.9 | 3.1 | 2.2 | 2.6 | 2.4 | 2.4 | 2.4 | 2.3 | 2.4 |
| A, 64 at once, 2,000 items | | 244 | 268 | 348 | 320 | 288 | 232 | 232 | 232 | 228 | 232 |
| A, 64 at once, 200 items | | 100 | 120 | 200 | 136 | 164 | 152 | 152 | 152 | 148 | 152 |
| A, 16 at once, 2,000 items | | 61 | 67 | 87 | 80 | 72 | 58 | 58 | 58.0 | 57.0 | 58.0 |
| A, 1 at once, 200 items | | 1.6 | 1.9 | 3.1 | 2.1 | 2.6 | 2.4 | 2.4 | 2.4 | 2.3 | 2.4 |
| Replay `2000_6` | | 116.1 | 108.9 | 104.9 | 66.3 | 52.4 | 50.3 | 49.3 | 49.3 | 49.3 | 49.3 |
| Replay `200_40` | | 13.1 | 13.1 | 10.9 | 9.8 | 8.3 | 7.4 | 5.6 | 5.6 | 5.6 | 5.6 |
| Synthetic `med` | 14.6 | 63.3 | 24.9 | 23.3 | 20.6 | 19.5 | 18.8 | 18.6 | 18.6 | 18.6 | 18.6 |
| Synthetic `mix` | 8.1 | 40.8 | 18.6 | 20.8 | 17.1 | 12.6 | 12.3 | 11.4 | 11.4 | 11.4 | 11.4 |
| Synthetic `grow` | 64.4 | 212.2 | 133.0 | 197.6 | out of memory | 87.6 | 71.8 | 70.8 | 70.8 | 70.8 | 70.8 |
| String loop, 20,000 steps | | 1,449.8 | 3.0 | 5.8 | 2.8 | 3.0 | 2.8 | 2.7 | 2.7 | 2.6 | 2.7 |
| String loop, 80,000 steps | | out of memory | 10.5 | 34.5 | 5.0 | 5.6 | 5.4 | 5.3 | 5.3 | 5.2 | 5.3 |
| Replay registry `reg_small` (200 requests) | | | | | | | | | 0.13 | 0.13 | 0.13 |
| Replay registry `reg_search` (214) | | | | | | | | | 0.13 | 0.13 | 0.13 |
| Replay registry `reg_releases` (204) | | | | | | | | | 0.56 | 0.56 | 0.56 |
| Replay registry `reg_closure` (177) | | | | | | | | | 0.56 | 0.56 | 0.56 |
| Replay registry `reg_compat` (151) | | | | | | | | | 0.13 | 0.13 | 0.13 |
| Replay registry `reg_mixed-ro` (400) | | | | | | | | | 0.56 | 0.56 | 0.56 |
| Replay registry `reg_mixed_c8` (400, 8 at once) | | | | | | | | | 1.00 | 1.00 | 1.00 |

The B rows at 64 at once and 2,000 items are the "fresh process, first id 1" row. v8 and the port have the same memory as v7 in all replay and synthetic rows (2026-11-07): they put each block where v7 puts it. The columns "v7, 2026-11-07", port and v8 are from `O=out/all-1107 scripts/all.sh v7 port v8` on a shared machine (load 5 to 12). They use the current hostlib (after the harness fix in "Build and run"), so they can differ from the v7 column of 2026-10-14 (B, 16 at once, 2,000 items: 20.7 against 15.3 MB). Compare v7, port and v8 inside these columns: the same memory in all rows (port 0.1 MB less in some rows). The page peak is probed only in versions with the `// probe: alloc` mark (not port, not v8). The registry rows (traces of the Talon registry Worker, section 6, "Registry traces") are from the port with the v8 paths: the same address for each block as v8 on all 7 traces (`scripts/same.mjs`). In A, v6 and v7 use more memory than v0 for small requests: each instance has the unit tables (about 0.9 MB of `.bss`). In B there is one copy.

### CPU: full app, µs per request

| Requests at once, items | Mode | v0 | v1 | v2 | v3 | v5 | v6 | v7 | v7, 2026-11-07 | port | v8 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1, 200 | A | 347 | 379 | 389 | 363 | 380 | 330 | 332 | 318 | 299 | 289 |
| | B | 198 | 217 | 202 | 202 | 211 | 204 | 203 | 131 | 125 | 128 |
| | B sum 1 | 210 | 205 | 208 | 205 | 212 | 208 | 206 | 124 | 128 | 120 |
| | B sum 2 | 205 | 204 | 210 | 210 | 210 | 208 | 204 | 124 | 130 | 120 |
| 16, 200 | A | 341 | 338 | 380 | 360 | 449 | 357 | 360 | 331 | 344 | 334 |
| | B | 201 | 201 | 214 | 222 | 231 | 215 | 219 | 133 | 141 | 123 |
| | B sum 1 | 218 | 206 | 217 | 222 | 234 | 219 | 222 | 129 | 138 | 123 |
| | B sum 2 | 231 | 215 | 221 | 226 | 227 | 222 | 229 | 135 | 135 | 127 |
| 64, 200 | A | 386 | 364 | 404 | 361 | 397 | 361 | 377 | 356 | 357 | 363 |
| | B | 218 | 211 | 222 | 215 | 223 | 221 | 214 | 144 | 158 | 134 |
| | B sum 1 | 251 | 222 | 230 | 220 | 226 | 216 | 216 | 164 | 149 | 133 |
| | B sum 2 | 285 | 235 | 243 | 227 | 228 | 220 | 221 | 153 | 147 | 150 |
| 1, 2,000 | A | 2,476 | 2,630 | 2,651 | 2,542 | 2,565 | 2,351 | 2,350 | 1,776 | 2,078 | 1,769 |
| | B | 1,852 | 1,885 | 1,959 | 1,943 | 1,935 | 1,930 | 1,921 | 1,203 | 1,172 | 1,085 |
| | B sum 1 | 2,026 | 1,924 | 1,972 | 1,960 | 1,963 | 1,964 | 1,949 | 1,172 | 1,250 | 1,189 |
| | B sum 2 | 1,985 | 1,926 | 1,972 | 1,952 | 1,969 | 1,958 | 1,942 | 1,385 | 1,200 | 1,344 |
| 16, 2,000 | A | 2,487 | 2,507 | 2,642 | 2,621 | 2,583 | 2,374 | 2,411 | 1,656 | 1,621 | 1,586 |
| | B | 1,888 | 1,909 | 1,974 | 1,950 | 1,983 | 2,044 | 1,982 | 1,166 | 1,218 | 1,169 |
| | B sum 1 | 2,031 | 2,002 | 1,998 | 2,003 | 2,031 | 2,054 | 2,080 | 1,216 | 1,221 | 1,570 |
| | B sum 2 | 2,156 | 2,101 | 2,022 | 2,028 | 2,081 | 2,131 | 2,100 | 1,214 | 1,352 | 1,300 |
| 64, 2,000 | A | 2,722 | 2,625 | 2,698 | 2,609 | 2,775 | 2,403 | 2,468 | 2,201 | 2,032 | 2,067 |
| | B | 2,053 | 1,959 | 2,021 | 1,999 | 2,021 | 1,968 | 1,995 | 1,824 | 1,703 | 1,647 |
| | B sum 1 | 2,120 | 2,025 | 2,055 | 2,031 | 2,060 | 2,047 | 2,053 | 1,777 | 1,537 | 1,570 |
| | B sum 2 | 2,223 | 2,084 | 2,059 | 2,087 | 2,089 | 2,132 | 2,110 | 1,697 | 1,848 | 1,911 |

All runs: 0 wrong bodies. Most allocator differences in this table are inside the 3 % noise. Use the replay for the allocator CPU. The 2026-11-07 columns (shared machine) have more noise, and B is about 35 % faster than in the 2026-10-14 column with the current hostlib (not looked into). Single rows differ up to 30 % in both directions (v8, 16 at once, 2,000 items, sum 1: 1,570 against 1,216 µs for v7), more than the allocator difference, so these columns do not rank the versions. Use the replay.

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

### CPU: replay, M instructions per trace (2026-11-07)

The machine was shared with other agents (load 5 to 12 on 24 cores), so wall time changed up to 2x between runs. `perf stat` counts the user-space instructions of a process; they change less than 1 % between runs. Each number: the instructions of a process that runs the trace N more times, minus a process that does not, divided by N (`scripts/pstat.mjs`), minus the same for `null` (the replay loop with no allocator). So it is the allocator alone. Instructions are not time (cache misses, branches), so the wall time is in the next table.

| Trace | Sums | v0 | v7 | port | v8 | v8, `set_small_room(4)` | v8 against port | port with the v8 paths | against port |
|---|---|---|---|---|---|---|---|---|---|
| `2000_6` | none | 711 | 1,496 | 1,606 | 1,318 | 1,214 | -18 % | 1,398 | -13 % |
| | sum 2 | 1,904 | 1,925 | 2,032 | 1,745 | 1,641 | -14 % | 1,816 | -11 % |
| `200_40` | none | 525 | 1,132 | 1,218 | 988 | 919 | -19 % | 1,046 | -14 % |
| | sum 2 | 2,135 | 1,410 | 1,515 | 1,272 | 1,212 | -16 % | 1,337 | -12 % |
| `med` | none | 15 | 63 | 65 | 60 | 61 | -8 % | 61 | -6 % |
| | sum 2 | 1,509 | 597 | 601 | 594 | 596 | -1 % | 596 | -1 % |
| `mix` | none | 14 | 33 | 36 | 29 | 30 | -18 % | 30 | -16 % |
| | sum 2 | 1,137 | 326 | 328 | 321 | 330 | -2 % | 324 | -1 % |
| `grow` | none | 22 | 48 | 48 | 44 | 44 | -9 % | 45 | -6 % |
| | sum 2 | 2,578 | 499 | 501 | 495 | 497 | -1 % | 495 | -1 % |
| `tiny` (3,986 tasks of 80 calls) | none | 19 | 66 | 71 | 63 | 62 | -11 % | 66 | -7 % |
| | sum 2 | 4,272 | 103 | 106 | 101 | 102 | -5 % | 100 | -5 % |
| `reg_small` (200 requests) | none | | 10.0 | 10.0 | 8.7 | 8.2 | -13 % | 8.9 | -11 % |
| `reg_search` (214) | none | | 15.4 | 17.0 | 14.5 | 14.0 | -15 % | 15.3 | -10 % |
| `reg_releases` (204) | none | | 19.3 | 20.9 | 18.0 | 17.1 | -14 % | 17.9 | -14 % |
| `reg_closure` (177) | none | | 70.7 | 76.8 | 63.7 | 63.7 | -17 % | 65.3 | -15 % |
| `reg_compat` (151) | none | | 21.8 | 23.9 | 18.7 | 19.0 | -22 % | 19.9 | -17 % |
| `reg_mixed-ro` (400) | none | | 137.1 | 149.7 | 122.8 | 124.2 | -18 % | 127.7 | -15 % |
| `reg_mixed_c8` (400, 8 at once) | none | | 138.3 | 150.8 | 124.8 | 124.4 | -17 % | 129.4 | -14 % |

The column "port" is the port before the v8 paths (with the counters of the stats header since P1). "port with the v8 paths" is `hostlib/alloc.zig` after the port of v8 (2026-11-07), from separate runs (`out/pstat_port_synth.txt`, `out/pstat_reg.txt`, 3 pairs; the p25 to p75 of a registry cell is about 0.5 M wide). It is 2 % to 6 % over v8: these are the 4 counter increments per call of the stats header, which v8 does not have (about 4.9 M on `reg_mixed-ro`, 1.17 M calls). The registry rows: the replay of the registry Worker's own calls only (about 0.04 M instructions per request); the allocator is 1 % to 3 % of the CPU of a registry request (`research/regprof`).

Wall time of the same versions, ms of allocator per trace (replay minus `null`), median of 9 interleaved rounds (`scripts/rcmp.mjs`), p25 to p75 in brackets. These runs were slower than the 2026-10-14 runs (v7 `2000_6`: 124 against 75 ms), so compare only inside a row.

| Trace | Sums | v7 | port | v8 | v8, `set_small_room(4)` |
|---|---|---|---|---|---|
| `2000_6` | none | 124 (114 to 142) | 129 (122 to 136) | 101 (94 to 101) | 115 (96 to 130) |
| | sum 2 | 181 (172 to 186) | 185 (162 to 196) | 153 (142 to 155) | 173 (145 to 177) |
| `200_40` | none | 59 (56 to 67) | 62 (61 to 71) | 47 (47 to 52) | 53 (52 to 57) |
| | sum 2 | 96 (95 to 107) | 101 (97 to 108) | 87 (84 to 91) | 90 (87 to 97) |
| `med` | none | 20.2 | 21.9 | 21.1 | 20.5 |
| | sum 2 | 117.5 | 119.3 | 119.0 | 117.8 |
| `mix` | sum 2 | 56.7 | 57.8 | 57.5 | 58.0 |
| `grow` | sum 2 | 89.7 | 92.6 | 92.1 | 90.5 |
| `tiny` | none | 6.5 (6.5 to 6.5) | 6.6 (6.6 to 6.7) | 5.9 (5.8 to 6.4) | 5.8 (5.8 to 5.9) |
| | sum 2 | 8.9 (8.8 to 9.0) | 9.0 (9.0 to 9.1) | 8.3 (8.2 to 8.3) | 8.4 (8.3 to 9.7) |

`set_small_room(4)` has fewer instructions, but its wall time was not better in this run: more page takes, and blocks of 2x the size. Not decided (see "Settings tried").

### CPU: full app, registry series (2026-11-07)

The total CPU of the workerd process (the registry Worker, Miniflare and local D1) on a fixed series, `research/regprof/cpuseries.mjs`: a fresh server per run, 100 warm-up requests, then `perf stat -p <workerd>` (all threads, user and kernel) minus 1 s of idle at the same rate. 5 rounds, variants interleaved; median (p25 to p75). `base` and `base again` are the same file (the A/A noise). Instructions are the measure: cycles and CPU ms changed 10 % to 50 % between rounds (shared machine, load 3 to 24), so they are not in the table. Apps: `variant-app.sh`.

| Series | Measure | base (port, 6c580d5) | base again | v9f | v9b1 | v9b2 |
|---|---|---|---|---|---|---|
| `mixed`, 2,000 requests | M instructions per request | 16.391 (16.366 to 16.407) | 16.400 (16.376 to 16.419) | 16.465 (16.453 to 16.477) | 16.393 (16.361 to 16.397) | 16.416 (16.406 to 16.430) |
| `mixed`, 2,000, 8 at once | M instructions per request | 16.055 (16.046 to 16.058) | 16.049 (16.042 to 16.056) | 16.109 (16.109 to 16.118) | 16.030 (16.024 to 16.037) | 16.041 (16.026 to 16.048) |
| `closure`, 500 | M instructions per request | 20.810 (20.795 to 20.822) | 20.836 (20.792 to 20.881) | 20.929 (20.915 to 21.022) | 20.795 (20.764 to 20.798) | 20.858 (20.846 to 20.875) |
| `releases`, 500 (8 rounds) | M instructions per request | 6.214 (6.202 to 6.235) | 6.210 (6.194 to 6.213) | 6.189 (6.110 to 6.209) | 6.177 (6.149 to 6.192) | 6.224 (6.129 to 6.243), 5 rounds |
| `mixed`, 2,000 | Peak wasm memory, MB; peak live KB in a request | 2.81; 511 | 2.81; 511 | 2.81; 511 | 2.81; 511 | 2.81; 511 |
| `mixed`, 8 at once | Same | 3.13; 771 | 3.13; 710 | 3.06; 771 | 3.13; 706 | 3.13; 704 |
| `releases` | Same | 2.50; 25 | 2.50; 25 | 2.50; 25 | 2.50; 26 | 2.50; 24 |
| Replay, peak of pages, KB | `reg_mixed_c8`, `reg_releases`, `2000_6` | 1,004; 508; 49,568 | | same as base | 968; 544 (+7 %); 49,716 | 1,020; 476; 49,568 |
| Replay, allocator M instructions | `reg_mixed-ro`, minus `null` | 128.8 | | 128.3 | 116.8 | 129.3 |

Response bodies (sha256) are the same in all variants and rounds of the series with 1 at once. With 8 at once, 7 to 12 of 2,000 differ between the rounds of each variant, `base` too: the order of the hint writes changes them, not the allocator.

The allocator is a small part of the total: the replay of the same requests is 0.32 M instructions per request (`reg_mixed-ro`), 0.37 M (`reg_closure`), 0.09 M (`reg_releases`), that is 2.0 %, 1.8 % and 1.4 % of the workerd instructions. An allocator that costs nothing would save at most that. All differences in the table are 0.6 % or less.

### Profile of v7 (2026-11-07)

Where the allocator CPU of v7 goes. Method: the instruction counts above with one part removed (`set_no_copy(1)`: the copy is not done; sum mode 0, 1, 2), the call counts of `scripts/tstats.mjs`, and self time per function with V8 inlining off (`replay/profbuild.sh`, `scripts/prof.mjs`, `node --no-wasm-inlining`).

| Part | `2000_6` (384 requests) | `200_40` (2,560 requests) | `tiny` (3,986 tasks) |
|---|---|---|---|
| Calls per request | 22,278: 8,100 small allocs, 6,000 small reallocs that move (`25 -> 46 -> 93 -> 182` B per item), 13 large | 2,488 | 80 |
| Allocator, no sums | 1,496 M instructions, about 190 µs per request | 1,132 M, about 21 µs per request | 66 M, about 1.2 µs per task |
| Small path (alloc, free, realloc without the copy) | About 1,290 M (86 %): about 150 instructions per call, v0 about 60 | Most | Most |
| Copies | 169 M instructions (11 %), 13 ms of 73. 131 MB of small blocks, 77 MB of large blocks | 108 MB | 9 MB |
| Page take and give (869,573) | 40 M (3 %): `set_keep_empty(1)` takes 16x fewer pages and saves only this | | |
| Sum mode 2 | +429 M (22 % of the total), about 78 µs per request | +278 M, about 7 µs per request | +37 M, about 0.4 µs per task |
| Memory grows | 789, under 0.3 % | | |
| Fixed cost of a task (micro trace `task`: 8 classes, a wait, task end) | | | About 5,900 instructions without sums, 7,900 with sum 2 |

Allocator share of a request (the full app in "CPU: full app"): about 10 % to 13 % at 200 and 2,000 items (sum mode 2), under 1 % for a tiny request. The 10 ms CPU limit of the free plan is not near for the allocator: a tiny request costs about 2 µs of allocator.

### Sums, copies and code size

| Measure | v0 | v1 | v2 | v3 | v5 | v6 | v7 | port | v8 |
|---|---|---|---|---|---|---|---|---|---|
| KB summed per wait, `2000_6` | 1,357 (heap walk) | 1,532 | 808 | 764 | 764 | 759 | 752 | 752 | 752 |
| KB summed per wait, `200_40` | 111 (heap walk) | 206 | 144 | 92 | 92 | 87 | 79 | 79 | 79 |
| MB copied by realloc, `2000_6` | 410 | 444 | 444 | 274 | 424 | 132 | 208 | 208 | 208 |
| MB copied by realloc, `200_40` | 246 | 203 | 203 | 115 | 330 | 101 | 108 | 108 | 108 |
| MB copied by realloc, `grow` | 155 | 356 | 356 | | 301 | 362 | 367 | 367 | 367 |
| Reallocs that grow in place, `2000_6` | | | | | | 4,185 | 3,518 | 3,518 | 3,518 |
| Lines of code (no blanks or comments) | 289 | 587 | 642 | 611 | 824 | 696 | 748 | 1,188 | 837 |

v6, v7 and v8 line counts include the research switches. PLAN.md step 6e removes them from the port. The port also has the global check (12d), the idle reset and the counters. The port column is from the replay of `hostlib/alloc.zig` (2026-11-07): the same pages, copies and memory as v7 on all traces.

### Wrong bodies after wild writes

Wrong bodies with status 200 in 20,000 requests:

| Words written | Sum mode | v0 | v1 | v2 | v3 | v5 | v6 | v7 | v7, 2026-11-07 | port | v8 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 16 | 0 | 39 | 5 | 4 | 5 | 9 | 5 | 17 | 31 | 33 | 28 |
| 256 | 0 | 358 | 105 | 68 | 102 | 86 | 87 | 273 | 362 | 320 | 374 |
| 4,096 | 0 | 239 | 589 | 523 | 416 | 620 | 514 | 319 | 291 | 277 | 238 |
| 16, 256, 4,096 | 1 or 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

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
| v7 | No reserve (`set_cache_max(0)`) (2026-11-07) | 48.6 | +25 % wall time (page takes go through the bitmap and the joins) | 131; 200 items 99 | Worse: the large copies go, the CPU goes up |
| v7 | Reserve of 16 pages (`set_cache_max(16)`) | 49.4 | Same | 177; 200 items 118 | No gain |
| v7 | Reserve of 64 pages | 49.7 | Same | 185; 200 items 141 | No gain |
| v7 | Keep one empty page per class (`set_keep_empty(1)`), CPU only | 52.9 | -40 M instructions of 1,330 (-3 %), 16x fewer page takes | 257 | Page churn is not the CPU cost |
| v8 | Base (2026-11-07): v7 with short paths | 49.3 (as v7) | -18 % instructions against the port, -12 % against v7 (no sums) | 208 (as v7) | Proposed |
| v8 | An empty small page with a free neighbor goes to the pool (`set_iso(1)`) | 49.3; `grow` 69.5 | Same or slower | 215; 200 items 123 | Worse |
| v8 | A small block that realloc moves gets a class for 1.5x its length (`set_small_room(2)`) | 49.8; 200 items 5.9 | Slower (more page takes) | 166; 200 items 132 | Worse |
| v8 | Same, for 2x its length (`set_small_room(4)`) | 49.1, pages peak 48.8 (+0.4); 200 items 5.7 (+0.1) | -7 % to -8 % instructions on `2000_6` and `200_40`; same on the synthetic traces | 162 (1.55 M copies, not 2.32 M); 200 items 102 | Promising. Needs a full-app memory test and the registry traces |
| v8 | Same, on the registry traces (2026-11-07) | Pages peak, KB: `reg_small` 124 to 140 (+13 %), `reg_releases` 508 to 696 (+37 %), `reg_closure` 384 to 392 (+2.1 %), `reg_mixed_c8` 1,004 to 1,024 (+2.0 %), others +0 to +2.1 % | 0 % to -4 % instructions (inside the noise on 4 of 7 traces) | 13 % to 19 % fewer copies; `reg_releases` 1,004 to 767 KB | Not ported: the rule was "port only if the peak grows 2 % or less" |

| v9f | No zero write of word 0 at a small alloc (option f) | Same | +0.3 % to +0.6 % total instructions (`mixed`, `closure`): Roc's refcount is at offset 4 of an 8-aligned block, so word 0 can keep an old free mark, and the free then walks the page's free list (`isDoubleFree`) | Same | Worse |
| v9b1 | Powers of 2 classes, 8 classes (option b, fewer) | Replay peak `reg_releases` +7 %, `2000_6` +0.3 %; full app the same | Allocator -9 % instructions (replay); total -0.6 % to 0 %, inside the noise | +26 % on `2000_6` | Fails the memory limit on `reg_releases`; no total gain |
| v9b2 | 21 classes, 4 per power of 2 up to 512 (option b, more) | Replay peak `reg_releases` -6 %, `reg_mixed_c8` +1.6 % | Total +0.1 % to +0.2 %, inside the noise | -4 % to -10 % (registry), +2 % (`2000_6`) | No gain |

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

## 6. Real apps: stats per request and traces

Two tools show what the allocator does for a real app (for example the Talon registry Worker). Both are in the platform, not in the harness of `build.sh`.

| Tool | Build | Switch | Output | Cost |
|---|---|---|---|---|
| Stats | Release host (the counters are always in it) | `makeHandler(app, { stats: true })` | Header `x-roc-stats` on each `fetch` response of the default export | Option off: none (no wrapper). Option on: one header and one JSON text for each request |
| Trace | Trace host: `zig build -Dtrace=true`, never the release build | `makeHandler(app, { trace: true })` or `{ trace: fn }` | Records of each allocator call | One JS call for each allocator call. For benches only |

### Build a bench variant of an external app

1. Make a COPY of the app (the app and the packages that it names with relative paths). Do not change the original.
2. In the copy of `main.roc`, change the platform URL to the local platform. The compiler refuses an absolute path: use a relative path, or a symlink to this repository.
3. Build it. For the registry: `$ROC build --target=wasm32 --no-cache --opt=speed --output=<dir>/app.wasm main.roc` (about 5 minutes). `ROC` is `.cache/nightlies/nightly-2026-10-31-f7bef6b/roc`. Never use `--opt=dev` on that nightly.
4. For a trace: first make a platform copy with the trace host, and point the copy of `main.roc` at it.

```
ZIG=<zig 0.17> research/alloc/trace-platform.sh <dir>    # <dir>/main.roc, <dir>/targets/wasm32/host.wasm
# platform "../cw/platform/main.roc"  becomes  platform "<relative path to <dir>>/main.roc"
```

The release platform (`platform/`) has the counters, so a stats build needs no trace host. The release host and the trace host use the same Roc code and the same header, so the same app source builds with either.

### Turn on stats

| Place | How |
|---|---|
| `worker.options.js` of the app (MODULES.md 3) | `export default { stats: true }` |
| A test run with `startApp` (`.roc-cfw/test.mjs`) and no way to give options | Env `CFW_TEST_OPTIONS='{"stats":true}'`. The option `options` of `startApp` is stronger |

The header is one compact JSON object. The counters are the counters of the wasm instance: a request that runs next to other requests counts their calls too. The values are those at the time of the response. The body that streams after it, and the work after `Response.after`, are not in them.

| Field | Meaning |
|---|---|
| `allocs`, `frees`, `reallocs` | Allocator calls in the request (all owners, JS blocks not counted) |
| `bytes` | Bytes asked for by allocs, and by reallocs that move the block |
| `livePeak` | Peak of live bytes since the start of the request (a window, `alloc_window`) |
| `liveEnd` | Live bytes of the instance at the response |
| `mem` | Wasm memory bytes at the response |
| `grows` | Memory grows in the request |
| `ms` | Wall time in the handler (the clock of the isolate: in workerd it moves only at I/O) |
| `served` | Fetches that this handler served since the isolate started |
| `ageMs` | Time since the first fetch of this handler |
| `inst` | Instance replacements (alarms, checks) since the start |

A real example (`bench/app_prod.roc`, 500 items, Node):

```
x-roc-stats: {"allocs":1871,"frees":1875,"reallocs":1234,"bytes":494679,"livePeak":250224,"liveEnd":0,"mem":2293760,"grows":0,"ms":2,"served":2,"ageMs":3,"inst":0}
```

The host counters are `alloc_stat(i)` and `alloc_window()` in `hostlib/alloc.zig`: four `u32` increments for each call, one for each grow, and one more compare in `liveAdd`. Cost, measured with `scripts/statcost.mjs` (the host before the counters against the host with them, interleaved, median of 21 rounds of 2,000 requests, Node 26.7):

| Build | 200 items, µs per request | 2,000 items, µs per request |
|---|---|---|
| Host before the counters | 366.5 | 1,053.8 |
| Counters, option off | 367.0 (+0.1 %) | 1,057.6 (+0.4 %) |
| Counters, option on | 383.9 (+4.7 %) | 1,071.8 (+1.7 %) |

The noise of a cell is about 10 % between rounds, so the first two rows are equal inside the noise. The option on costs 17 µs for each request (a header, `JSON.stringify`, a few export calls).

### Record a trace

The trace host calls `js_trace(op, owner, a, b, c)` at each top-level allocator call. `js/trace.js` writes the records in the format that `scripts/replay.mjs` and `replay/` read.

| Item | Value |
|---|---|
| Record | 4 x u32: `[op \| align << 8 \| offset << 16, owner, id, len]` |
| Ops | 1 alloc, 2 free, 3 realloc, 4 task end, 5 sum (a wait), 6 adopt |
| Offset | The pointer of a free or realloc minus the pointer that alloc gave |
| Ids | Reused after a free |
| Not in the trace | Blocks of JS (`js_alloc`) and of the host (log, response): a free of a block that the trace did not see is a miss, not a record. `Handler.traceStats.misses` counts them |

| Option | Result |
|---|---|
| `trace: true` | The records are kept. `Handler.takeTrace()` gives the records since the last call (a `Uint32Array`) |
| `trace: fn` | After each event `fn(records)` gets the records of that event. The chunks of one isolate join into one trace (the ids go on) |

The shim writes no file: workerd has no file system. A function in `worker.options.js` cannot write either, because the Worker runs in workerd. Under `startApp` (`.roc-cfw/test.mjs`, Node), use the env var:

| Item | Value |
|---|---|
| Env `CFW_TEST_TRACE=<file>` | `startApp` sets the option `trace: true`, and `close()` appends the records of the isolate to `<file>`. Needs an app on the trace host (else `startApp` fails: no `js_trace`) |
| `app.takeTrace()` | The records since the last take (control path `trace` of the test entry); the file then gets only the rest |
| Stop | `close()` must run before workerd stops. Miniflare stops workerd on its own on SIGTERM, so a server that calls `close()` on SIGTERM can lose the trace. `research/regprof/regserve.mjs` has `POST /__regserve/stop` for this |
| Test | `test-helper/trace-env-test.mjs` (in `bench/test-all.sh`) |

Then replay it:

```
ZIG=<zig> research/alloc/replay/build.sh port v7        # replay_port.wasm: the allocator of the platform
cd research/alloc && node scripts/replay.mjs <name> 5 port v7
```

The replay of a real app has waits with no allocator call of the task before its next wait. In sum mode 2, `bad` then has a high part (1 << 16 for each such wait). Only `bad & 0xffff` counts sums that differ.

`bench/trace-test.mjs` checks the whole path: a known route traced, replayed on the platform allocator with no trap and no sum difference.

### Registry traces

`scripts/regtrace.sh` records one trace for each scenario of `research/regprof/scenarios` (made for the local registry server): a fresh server for each scenario (`research/regprof/serve.sh`, seed of `state/`), the requests of `talon/research/bench/drive.mjs`, then the stop route. Output: `out/trace_reg_<scenario>.bin` and the drive log `out/reg_<scenario>.jsonl` (gitignored).

```
W2_DIR=<build dir: app.wasm on the trace platform, .roc-cfw/ with the current js/> \
  scripts/regtrace.sh small:1:100 search:1:2 releases:1:3 closure:1:3 compat mixed-ro mixed:8   # scenario:concurrency:repeat
```

| Trace | Requests | Records | Allocs and reallocs | Waits | Status not as expected |
|---|---|---|---|---|---|
| `reg_small` | 200 (2 x 100) | 64,958 | 33,749 | 204 | 0 |
| `reg_search` | 214 | 114,444 | 58,476 | 856 | 0 |
| `reg_releases` | 204 | 144,594 | 74,640 | 682 | 0 |
| `reg_closure` | 177 | 580,053 | 294,096 | 708 | 0 |
| `reg_compat` | 151 | 175,850 | 89,920 | 868 | 0 |
| `reg_mixed-ro` | 400 | 1,168,664 | 591,070 | 1,420 | 0 |
| `reg_mixed_c8` | 400, 8 at once | 1,173,709 | 593,784 | 1,478 | 0 |

The registry holds little memory: at most 1 MB of pages (`reg_mixed_c8`), and a few KB of live bytes per request. All traces replay on v7, the port and v8 with `bad & 0xffff` = 0 in sum mode 2 and no live byte at the end.

### v9: tries on the total CPU of the registry (2026-11-07)

Goal: less total CPU of the registry Worker on real series, not only allocator instructions (table "CPU: full app, registry series"). `versions/v9.zig` is the port at 6c580d5. Each `v9<x>.zig` changes one thing. Result: no try changed the total by more than the noise (0.6 %). The allocator is 1.4 % to 2.0 % of the workerd instructions, so the upper limit of any allocator change is about 2 %.

| Option | Tried | Why not more |
|---|---|---|
| a. Locality, reuse order | Not built | The free list is LIFO, and the page that gets a free goes to the head of its list (hot first). Block life on `reg_mixed-ro`: median 4 calls, p90 171 calls, so the reused block is in cache already |
| b. Size classes | v9b1, v9b2 | No total gain; v9b1 fails the memory limit |
| c. Pages of 8 or 16 KB for small classes | Not built | Page takes and gives: about 160 per request on `reg_mixed-ro`, about 0.1 % of the total instructions at most |
| d. Realloc headroom | Not built | 15,296 reallocs of 575,774 allocs; copies 17 KB per request (`reg_mixed-ro`), about 2 µs per request of 3 ms CPU (0.06 %) |
| e. Reaps (bump for the life of a task) | Not built | A request allocates about 43 KB on average (more for `closure`), and 8 at once would hold all of it: the peak goes up many times over the live peak (771 KB) |
| f. Less work for the checks | v9f | Worse (see "Settings tried"). The free mark is kept |

Builds: `variant-app.sh` builds the registry copy on a variant host in about 2.5 min (not 5): the Roc cache is on, and only the platform copy (`.../pfv`) changes between builds.

### v8: short paths for small blocks (2026-11-07)

v7 with the same tables, pages, runs and placement, so memory, copies, sums and grows are the same as v7 on all traces (checked: equal memory, peak, KB summed, copies, MB copied, page takes and grows in place). Only the code paths change:

| Path | v7 (and the port) | v8 |
|---|---|---|
| Free of a small block | `blockUnit` (2 compares), `release` (task record, kind again, class 3 times, start), `smallFree` | One range compare, kind and class read once, the start once; the task record only on the slow path (page was full, or is now empty) |
| Alloc of a small block | `taskOf`, `allocIn`, `smallAlloc` (a loop with the bump, the next page, a new page) | `smallTake`: the free list or the bump of the current page; else the slow path (`smallAlloc`, as v7) |
| Realloc that moves a small block | `usableAt` and `release` each find the block start; the new block through `allocIn` | The start once; the new block through `smallTake`; the old block freed with its known start |
| Task slot of a new owner | Scan of 254 slots | Home slot `1 + (owner & 127)` first, then the scan |
| Research switches on the hot path | `KEEP_EMPTY`, `PAGE_CACHE` | Removed (fixed as the v7 defaults) |

v8 has the checks of the port that are on the hot path (`mayFree`, the live peak), so v8 against the port is a fair compare. A port of v8 changes only the hot functions of `hostlib/alloc.zig`; the global check (12d), sums, `idleReset` and the counters of the stats header do not change.

Result: 14 % to 19 % fewer allocator instructions than the port on the app traces, and 8 % to 24 % less wall time on the app traces and `tiny` (noisy machine, see "CPU: replay, M instructions"). The same on the synthetic traces with large blocks (`med`, `grow`), which spend their time in the run index, the copies and the sums.

Port (2026-11-07): `hostlib/alloc.zig` has the v8 paths (`smallTake`, `smallRelease` and `smallFreeSlow`, `isDoubleFree`, `startIn`, the fused free and the small realloc, the home slot). Not changed: placement, the trace hooks, the counters of the stats header, the bench hooks (`ALLOCS`, `FAIL_AT`), `mayFree`, the live peak, the sums, `idleReset` and the global check. `set_small_room` is not in the port (see "Settings tried"). Checks:

| Check | Result |
|---|---|
| `scripts/same.mjs <trace> v8 port`: the same address for each alloc and realloc | Same on the 7 registry traces and on `2000_6`, `2000_1`, `200_40`, `med`, `mix`, `grow`, `tiny`, `micro_task`, `micro_chain` |
| Instructions (table "CPU: replay, M instructions") | -10 % to -17 % against the port before; +2 % to +6 % against v8 (the stats counters) |
| `bench/test-all.sh` | ALL PASS |

Mutations of the new paths (`mut/run.sh <name>`: one change, then `bench/alloc-test.sh`, then the file back):

| Mutation | Caught by |
|---|---|
| `dfree`: no double-free check in `smallRelease` | `bench/dfree.mjs` |
| `slow`: the slow path only for an empty page (a page that was full does not go back to its list) | `bench/fastpath.mjs` 1 (global check 8, the freed block not used again) |
| `mayfree`: the fused free does not call `mayFree` for a small block | `bench/dfree.mjs` case 2 (a block of B freed by A) |
| `home`: a new owner takes its home slot when another task has it | `bench/fastpath.mjs` 2 (task 1 loses its record: global check 10, sum changed) |
| `usable`: the small realloc does not subtract the offset of the pointer | `bench/fastpath.mjs` 3 (no move, the next block changed) |
| `range`: the range compare accepts the unit at `POOL_HI` | Not caught. No effect: that unit is never small or large, so the free is a miss as before |

`bench/fastpath.mjs` is new (in `bench/alloc-test.sh`). Before it, `slow`, `home` and `usable` were not caught by a test (`slow` only by `same.mjs`).

What v8 does not change, and why:

| Cost | Share (v7, `2000_6`, sum mode 2) | Why not changed |
|---|---|---|
| Sums | 22 % of the instructions, 30 ms per 384 requests | A content sum (Fletcher, 2 lanes of u64) over the task's bytes, at about 0.1 cycle per byte: near the cache bandwidth. A byte counter cannot replace it (it must see a wild write). A sum without the second lane has fewer instructions (not measured), but does not see two words that change places. |
| Copies of small blocks that realloc moves | 131 MB of 208 MB, 2.3 M copies | The class of a block is fixed. `set_small_room(4)` cuts the copies by a third (see "Settings tried") |
| Copies of large blocks | 77 MB (v6: about 1 MB) | The reserve holds units that 2x runs would use. All fixes tried (reserve size, `set_iso`, placement) cost CPU or memory. 5 % of the allocator time. |
| Page take and give (869,573 on `2000_6`) | 3 % of the instructions | The reserve makes each one a push or a pop |
| Fixed cost of a task (start, first pages, task end) | About 6,000 instructions per task with 8 classes, about 1.3 µs | Small against the 10 ms CPU limit; v8 is the same |
| Memory grows | 789 grows on `2000_6`, at about 0.3 µs each | Under 0.3 % of the allocator time; a larger first memory or grow step gains nothing measurable |

