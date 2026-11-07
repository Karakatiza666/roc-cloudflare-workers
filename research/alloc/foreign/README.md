# Foreign allocators: the total speed of the registry (2026-11-07)

Question: can an allocator of a different design make the whole app faster through cache, TLB or locality effects (as mimalloc does in some native apps), with at most 5 % more memory? The earlier tries (`../README.md`, v9) changed only details of v8 and measured only instructions, which cannot see those effects.

Short answer: no. On the Talon registry Worker (local, and on real Workers within a 13 % to 25 % interval) no allocator changed the total instructions by more than 1.7 %, or the cache-miss and L1-miss counts by more than the A/A noise (about 1 to 3 %). The ceiling (a bump allocator) gains 1.7 % of instructions and no cache effect. Local cycles were too noisy to see a change below about 5 %. On Cloudflare (section "Edge") no A/B differs from base beyond the A/A noise.

## Files

| File | Use |
|---|---|
| `fa.zig` | The adapter: one backend behind the API of `hostlib/alloc.zig`. No task pages: task sums give a constant, the global check passes, a trap leaks the task's blocks (backend `tl` frees them). JS blocks (`js_alloc`) get a 16 B header with a mark, so the frees at the bytes or at the refcount find the start |
| `fa_tl.zig` | Backend `tl`: my design (e), a reap per task (below) |
| `dl.c`, `em.c`, `mi.c`, `em_inc/` | The C backends and their config; libc stubs for mimalloc and emmalloc |
| `fetch.sh` | Downloads dlmalloc (wasi-libc), emmalloc (emscripten), mimalloc 2.2.4 into `vendor/` (gitignored) |
| `gen.sh` | `gen/fa_<b>.zig` and, for a C backend, `gen/<b>.o` (zig cc, wasm32) |
| `app.sh` | The registry on a host with backend `<b>`: `gen.sh`, `../variant-app.sh` with `SUM_OFF=1` (the release host takes sum mode 0) and `EXTRA_OBJ` (wasm-ld -r merges the C object into the host object) |
| `stats.mjs` | Tables (median, IQR, change against base) from `cpuseries.mjs --out` files; `--rounds a-b` |
| `mkedge.sh`, `edgerun.sh`, `edgecpu.mjs`, `edgeci.mjs` | Edge A/B: deploy folders, one phase of requests, CPU per version and D1 rows from the GraphQL analytics, bootstrap intervals |

`../replay/build.sh fa_<b>` builds the replay of a backend; `../variant-platform.sh` has the new env `EXTRA_ZIG`, `EXTRA_OBJ`, `SUM_OFF`; `../../regprof/cpuseries.mjs` has the new options `--events`, `--cpu`, `--node-cpus`, `--v8` and `<name>=<dir>@off`.

```
ZIG=<zig 0.17> REG=<registry copy> foreign/app.sh dl            # REG/w2-fa_dl
node ../regprof/cpuseries.mjs --series mixed:2000:1,mixed:2000:8,closure:1000:1 --rounds 9 --warm 300 \
  --cpu 2 --node-cpus 8-11,20-23 --v8 "--no-liftoff --no-wasm-lazy-compilation" \
  --events cycles,instructions,cache-misses,L1-dcache-load-misses,dTLB-load-misses,page-faults \
  --out foreign/out-final.json base=$REG/w2-fbase@off base2=$REG/w2-fbase@off dl=$REG/w2-fa_dl@off
node foreign/stats.mjs foreign/out-final.json --rounds 1-5
```

## The allocators

| Name | Design | Built | Notes |
|---|---|---|---|
| base | v8 port (`hostlib/alloc.zig`), sums and global check off | yes | The control |
| bump | Bump, never frees, 16 B header | yes | 80 MB after 300 mixed requests: out of memory on the series. Only the smoke run |
| bumpr | Bump; the break goes back to the start when no block is live | yes | The locality ceiling: each request reuses the same low bytes |
| zig | `std.heap.wasm_allocator` (Zig 0.17: `BrkAllocator`, power-of-2 classes), 16 B header for the length | yes | |
| dl | dlmalloc, wasi-libc config (alignment 16, no mmap), `sbrk` from `fa.zig` | yes | |
| em | emmalloc (alignment 8, as in emscripten) | yes | Its live count is wrong (usable size changes): ignore its live peak |
| mi | mimalloc 2.2.4, wasi prim with `MI_USE_SBRK`, arena reserve 4 MiB | yes | Segments of 4 MiB on wasm32: 12 MB on the registry (4.3x base). Fails the memory rule |
| tl | Design (e): a reap per task. Each task bumps in its own 32 KB chunks, 8 B header (size, slot), LIFO free lists per task and class (32 classes up to 4 KB), growth in place at the bump end, blocks above 4 KB in runs of 4 KB pages (best fit, joined), chunks to a LIFO cache at task end | yes | A task's memory is a few contiguous ranges (a cheap sum) |

All builds gave the same response bodies as base on every series with 1 request at once. With 8 at once, 31 to 38 of 18,000 bodies differ in every variant, base2 too: the order of the hint writes, not the allocator.

## Measurement

Total CPU of the workerd process (registry, Miniflare, local D1) on the registry series of `../../regprof`. Changes against `cpuseries.mjs` of v9:

| Change | Why |
|---|---|
| workerd pinned to one CPU (`taskset -a`), the node server and the client on other CPUs (another L3) | Less migration and sharing |
| `--no-liftoff --no-wasm-lazy-compilation` | Without it, the TurboFan tier-up of the 5 MB wasm runs in background threads during the idle second and the series: the instructions per request changed by up to 5x between runs. With it, all wasm is compiled at the start |
| 300 warm-up requests | JS JIT in steady state |
| 6 hardware events, no multiplexing (checked: 100 % counted) | Cache, L1 and TLB misses |
| 9 rounds, variants interleaved, A/A pair | Noise of each metric |

### A/A noise (base against base2, final run, rounds 1 to 5 before other load came)

| Metric | Change of the median | IQR of a variant | Use |
|---|---|---|---|
| Instructions | 0.0 % to 0.1 % | 0.0 % to 0.4 % | Good |
| cache-misses | -0.2 % to -1.0 % | 0.5 % to 3 % (closure up to 12 %) | Good to about 2 % |
| L1-dcache-load-misses | -0.3 % to +2.8 % | 0.6 % to 7 % | Good to about 3 % |
| dTLB-load-misses | +1 % to +12 % | 3 % to 16 % | Bad |
| page-faults | -3 % to +3 % | 1 % to 11 % | Bad |
| Cycles | -0.7 % to -4.7 % | 3 % to 43 %; paired rounds swing 5 % to 50 % | Bad: below 5 % not visible |
| CPU ms (/proc) | -4.9 % to +5.8 % | 3 % to 24 % | Bad |

The machine was shared (other agents, load 3 to 30 during the screening). A quiet window was given for the final run; from about 20:29 (round 6 of 9) another session ran 4 Zig builds (load 9 to 10). Rounds 6 to 9 are marked loaded; the tables use rounds 1 to 5. Even the quiet rounds had a cycles IQR of 3 % to 16 %.

### Results, final run, rounds 1 to 5, change against base

| Series | Metric | base | base2 (A/A) | bumpr (ceiling) | zig | dl | tl |
|---|---|---|---|---|---|---|---|
| `mixed`, 2,000, 1 at once | Instructions, M per request | 14.962 | -0.02 % | -1.61 % | -1.18 % | -1.17 % | -0.18 % |
| | cache-misses, M | 0.203 | -0.9 % | -1.1 % | -0.8 % | -0.2 % | -0.6 % |
| | L1-dcache-load-misses, M | 0.110 | -0.3 % | +0.5 % | -0.8 % | -1.2 % | -0.1 % |
| | Cycles, M | 8.86 (IQR 8 %) | -1.6 % | -1.4 % | -2.6 % | +0.6 % | +1.3 % |
| | Peak wasm memory, MB | 2.81 | 2.81 | 4.25 (+51 %) | 3.56 (+27 %) | 1.75 (-38 %) | 2.19 (-22 %) |
| `mixed`, 2,000, 8 at once | Instructions | 14.993 | -0.01 % | -1.69 % | -1.44 % | -1.26 % | -0.40 % |
| | cache-misses | 0.155 | -0.5 % | -1.0 % | -0.5 % | +0.1 % | +0.8 % |
| | L1-dcache-load-misses | 0.110 | -0.4 % | +0.2 % | -1.0 % | -0.6 % | +0.8 % |
| | Cycles | 8.32 (IQR 9 %) | -4.7 % | -6.4 % | -4.0 % | -3.8 % | +1.0 % |
| | Peak wasm memory, MB | 3.13 | 3.06 | 6.19 (+98 %) | 3.88 (+24 %) | 2.06 (-34 %) | 2.69 (-14 %) |
| `closure`, 1,000 | Instructions | 19.288 | +0.13 % | -1.71 % | -1.08 % | -1.10 % | -0.48 % |
| | cache-misses | 0.278 | -0.2 % | -2.7 % | -1.9 % | +2.4 % | +0.9 % |
| | L1-dcache-load-misses | 0.182 | +2.8 % | -3.1 % | -3.2 % | +1.0 % | +0.2 % |
| | Cycles | 13.17 (IQR 16 %) | -0.7 % | -14.5 % | -10.5 % | +5.1 % | +6.0 % |
| | Peak wasm memory, MB | 2.81 | 2.81 | 4.25 | 3.56 | 1.75 | 2.19 |

Screening (5 rounds, under load, also with emmalloc and mimalloc, `out-screen.json`): em +0.7 % to +1.4 % instructions, mi -0.2 % to -1.1 %; no cache-miss change beyond 3 %; memory em +20 % to +80 %, mi +220 % to +330 %. The production config (base with sums and the global check on) costs +3.2 % instructions on `mixed` and +9.9 % on `releases` against base with them off: the idle global check after each request is most of it.

Replay of the registry traces (allocator alone, ms, Node, noisy; memory grown, MB):

| Trace | port | bumpr | zig | dl | em | mi | tl |
|---|---|---|---|---|---|---|---|
| `reg_mixed_c8` ms | 35.1 | 16.1 | 11.7 | 23.3 | 25.5 | 19.1 | 11.1 (other run: port 13.6) |
| `reg_mixed_c8` MB | 1.0 | 7.9 | 2.4 | 0.8 | 0.9 | 9.9 | 1.4 |
| `2000_6` MB (the 2,000-item app) | 49.3 | 116.1 | 69.0 | 48.2 | 56.7 | 65.9 | 87.4 |

### What the numbers say

| Finding | Evidence |
|---|---|
| The ceiling is small | A bump allocator that reuses the same bytes for each request (the best locality possible) saves 1.6 % to 1.7 % of the instructions and does not lower the cache-miss or L1-miss counts beyond the noise |
| No locality effect on this app | All allocators keep cache-misses and L1 misses within -3 % to +2.4 % of base, the same range as the A/A pair. The registry heap is 2 to 3 MB and a request holds about 0.5 MB live: it fits in the 1 MB L2 and the L3 with any allocator. The hot data of a request is the Roc data, the JS shim, workerd and SQLite, not the allocator's layout |
| The instruction gains are the allocator's own path | zig and dl: -1.2 %; the allocator is 1.4 % to 2 % of the instructions (`../README.md`). That is a cheaper alloc and free (no per-unit tables, no `mayFree`, no live peak), not an effect on the rest of the program |
| Cycles cannot confirm a gain under 5 % on this machine | A/A median change up to 4.7 %, paired round swings up to 50 % even with pinning and a quiet window. The cycles of zig and bumpr on `closure` (-10 % to -15 %) are inside the closure A/A IQR (16 % to 43 %), and the same variants were +20 % in the loaded rounds |
| dlmalloc has less memory | 34 % to 38 % less peak wasm memory than base on the registry (1.75 against 2.81 MB), and 2 % less on the 2,000-item replay. Cause: no 4 KB page per size class and per task (base has up to 13 classes x tasks partly empty pages), and no reserve of 256 empty pages |

Step 3 of the plan (find the effect, port it into the per-task design with sums) is not done: no allocator won on total cycles beyond the noise, and the miss counters show no effect to port.

## Edge

Gradual deployments at 50/50 on `talon-registry-bench` (Workers Paid; the lead deployed, builds from the current `talon/worker` source, `edge/<name>` from `mkedge.sh`, sums and global check off in all versions). One phase: `edgerun.sh <phase> mixed 5 4` (2,000 `mixed` requests from ATH, 4 at once, about 33 s), then `edgecpu.mjs` (quantiles per version) and `edgecpu.mjs`-style per-second groups in `edgeci.mjs` (95 % bootstrap intervals over the seconds, paired: the analytics give no per-request CPU). The control is the same version (bbdf156c) in all phases.

| Phase | Versions (a, b) | Requests a, b | CPU p25, µs | CPU p50, µs | CPU p75, µs | Mean CPU b/a - 1 (95 % CI) | Per-second p50 b/a - 1 (95 % CI) | D1 rows read |
|---|---|---|---|---|---|---|---|---|
| A/A | base bbdf156c, base 9351ef2f | 999, 987 | 2,040; 1,996 | 2,750; 2,492 | 4,626; 4,644 | -9.5 % (-21.0 % to +4.1 %) | -5.0 % (-16.1 % to +16.0 %) | 5.10 M |
| dl | base, dl dbc79879 | 979, 1,018 | 2,140; 2,053 | 2,840; 2,595 | 4,636; 4,456 | -2.0 % (-13.2 % to +11.7 %) | -0.2 % (-20.4 % to +25.2 %) | 5.10 M |
| zig | base, zig 9ff62b85 | 989, 998 | 2,233; 2,065 | 2,782; 2,829 | 4,928; 4,696 | +0.8 % (-13.3 % to +15.9 %) | +0.3 % (-22.7 % to +15.0 %) | 5.08 M |

Each phase had the same 15 unexpected statuses: `POST /v1/compat` 200 in place of 201 (the scenario's report again on passes 2 to 5: it exists already), in A/A too, so not allocator related (the response has no version id, so they cannot be split by version). Errors: 0 in all versions. Memory per version is not in the edge analytics (the stats header was off); the same builds locally on `mixed`: base 2.81 MB, dl 1.75 MB, zig 3.56 MB.

Result: the A/A pair differs by up to 9.5 %, and each A/B interval is about +-13 % to +-25 % wide and holds 0. One phase of 2,000 requests cannot resolve the 1 % to 2 % that the local instructions allow. The heavy tail (p99 30 to 36 ms: the lazy compile of the wasm in a new isolate) sets most of the mean's noise. No win is claimed.

## Recommendation

| Item | Recommendation |
|---|---|
| Change the platform allocator for speed | No. The best possible allocator (ceiling) gives 1.7 % fewer instructions and no cache effect on the registry. Smaller than the cost of the sums and global check (3 % to 10 %) |
| Where speed is | The global check after each request (+3 % to +10 % instructions, `releases` most) and the sums, not the allocator |
| Memory | dlmalloc's layout uses 35 % less memory on small apps. If memory ever matters, the per-task design could take the lesson: share partly empty pages less per class (fewer classes for a small task, or pages of 1 KB for the first blocks of a class). Not needed now: the registry uses 3 MB of 128 MB |
| My design `tl` (reap per task) | No speed gain (-0.2 % to -0.5 % instructions), 14 % to 22 % less memory on the registry, but +77 % on the 2,000-item app (32 KB chunks per task). Its plus is a sum over few contiguous ranges per task; not worth a port for speed |
