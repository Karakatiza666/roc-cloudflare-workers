# JSPI concurrency bench

Question: a Roc wasm32 app with a Zig host serves concurrent requests that wait on async JS calls (JSPI). Which model is better in workerd?

| Variant | Model | Cost of a wait |
|---|---|---|
| A | One precompiled `WebAssembly.Module`. Each request makes `new WebAssembly.Instance`, calls `handle` through `WebAssembly.promising` | None. One instance runs one request |
| B | One shared instance for all requests | A wait copies the used shadow stack `[sp, TOP)` to the heap and sets `__stack_pointer` to TOP. The resume copies it back to the same addresses (`../host/host.zig`) |
| JS only | No wasm. The same two waits and body, in JS | Floor of workerd and the load generator |

## Files

| File | Content |
|---|---|
| `../host/host.zig` | Host. `waitBegin`/`waitEnd` and `getSP`/`setSP` (copy), `roc_wait`, `handle`, `task_abort`, `copy_bench`, counters |
| `../hostlib/` | Allocator, canary, Roc callbacks |
| `../platform/main.roc`, `../platform/Wait.roc` | Platform: `requires { handle! : Str => Str }`, one hosted `Wait.wait!(kind, num, a, b, c)` |
| `app.roc` | Handler: 200 records to JSON (about 300 KB of heap), recursion `depth` levels with a kept value per level, two waits (fetch: 5 ms, db: 1 ms), body with the request id and a stack checksum |
| `core.js` | JS shim: `makeRunner(module, "a" or "b", io)`, the `js_wait` import, the body check. "b" falls back to "a" when `stack_first()` is 0, and uses a new instance after an unclean trap |
| `app_deep.roc`, `overflow-test.mjs` | Stack overflow test: recursion with a wide record per level, with and without an allocation per level |
| `oneinstance-test.mjs` | One instance per isolate (PLAN.md 4a): 1,000 requests with 1 % unclean traps, never more than 1 instance with a task, 0 bad bodies |
| `app_wait.roc`, `cpu-test.mjs` | CPU flags of workerd (PLAN.md 5a to 5c): the exported globals, the signal (clean trap with cause "cpu"), the terminated flag (replace). `app_wait.roc` has one wait and no allocation |
| `app_strloop.roc`, `strloop-test.mjs` | Bug B5 (PLAN.md 6e): a string that grows in a loop. Wasm memory must stay under 6 MB |
| `alloc-test.sh`, `alloc_driver.zig`, `dfree.mjs`, `fmark.mjs`, `reserve.mjs`, `adopt.mjs`, `sumjs.mjs` | Allocator tests (PLAN.md 6e) on a driver built from `../hostlib/`: double free, free after the page went to another task, a live block with the free mark, the page reserve at the memory cap, adopted JS blocks at `freeOwner` and in `sumTask` |
| `check-layout.mjs` | Reads a linked wasm: STACK-FIRST, DATA-FIRST or UNKNOWN (exit 0, 1, 2) |
| `get-roc.sh`, `ci-layout.sh`, `../compat/last-stack-first-nightly` | Nightly download, the CI check of one nightly (`../.github/workflows/nightly-layout.yml`), the pinned nightly |
| `worker.js`, `echo.js`, `config-{a,b,j}.capnp` | workerd worker, echo service binding, one config per variant |
| `bench.mjs` | Load generator (Node fetch, concurrency pool) and driver: fresh workerd per variant and rep |
| `owner.mjs` | Cost of owner tags: alloc + free, heap walk per trap, whole request. Two builds, tags on and off |
| `micro.mjs` | CPU cost in Node with a real clock: instantiate, copy work alone, per request by depth |
| `summarize.mjs` | Markdown tables from the `bench.mjs` output |

## Reproduce

```sh
ZIG=<zig 0.17> bench/build.sh   # roc: the nightly in compat/ (ROC= to override)
node bench/node-test.mjs bench/out/app.wasm                      # smoke test, both variants
node bench/overflow-test.mjs bench/out/app_deep.wasm             # stack overflow
node bench/oneinstance-test.mjs bench/out/app.wasm               # one instance (4a)
node bench/cpu-test.mjs                                          # CPU flags (5a to 5c)
node bench/strloop-test.mjs bench/out/app_strloop.wasm           # string loop (B5)
ZIG=<zig 0.17> bench/alloc-test.sh                               # allocator tests
bench/ci-layout.sh <nightly tag>                                 # what CI runs for a new nightly
WORKERD=<workerd 2026-10-12> node bench/bench.mjs 3 5000 > .cache/results/bench.jsonl
WORKERD=<workerd> node bench/bench.mjs leak 10000 0.01 > .cache/results/leak.jsonl
node bench/summarize.mjs .cache/results/bench.jsonl .cache/results/leak.jsonl
node bench/micro.mjs bench/out/app.wasm bench/out/app_pad.wasm
ITEMS=0 node bench/micro.mjs bench/out/app.wasm bench/out/app_pad.wasm   # no JSON work
# Owner tags: two builds with track_live off, tags on and off
ZIG_FLAGS="-Dtrack_live=false" OUT=bench/out-on bench/build.sh
ZIG_FLAGS="-Dtrack_live=false -Downer_tag=false" OUT=bench/out-off bench/build.sh
bench/build.sh                                                   # back to the default host
node bench/owner.mjs bench/out-on/app.wasm bench/out-off/app.wasm
```

`build.sh` sets `ROC_CACHE_DIR`, `XDG_CACHE_HOME` and `ZIG_GLOBAL_CACHE_DIR` to `.cache/` (ignored). Request: `GET /h?id=&trap=0|1&depth=`. Depth to copy size: 1.8 KB + 480 B per level (0: 1.8 KB, 30: 16 KB, 130: 63 KB, 530: 250 KB).

## Results (2026-10-13, 24 cores, a parallel job loaded the machine: load average 5 to 10)

Expect noise of about 20 % between reps. Each workerd cell: 5000 requests after a 1000 request warmup, median of 3 reps. Errors and bad bodies are summed over the reps.

### Per wait copy cost (Node, `micro.mjs`)

| Copy size | Copy work alone (`copy_bench`) us/wait | Whole request with no JSON (`ITEMS=0`), B minus B without copy, us/wait |
|---|---|---|
| 1 to 2 KB | 0.05 | below noise |
| 16 KB | 0.18 to 0.23 | below noise |
| 64 KB | 1.4 to 1.8 | 1.2 to 1.4 |
| 256 KB | 5.2 to 6.8 | 3.8 to 6.2 |
| 720 KB | 21 to 35 | - |

### CPU per request (Node, `micro.mjs`, waits resolve at once, us)

| Depth (copy) | With JSON: B | With JSON: A | No JSON: B | No JSON: A | No JSON, 64 at a time: B | No JSON, 64 at a time: A |
|---|---|---|---|---|---|---|
| 0 (1.8 KB) | 205 | 306 | 7 | 60 | 12.5 | 95 |
| 30 (16 KB) | 211 | 316 | 10 | 87 | 17 | 95 |
| 130 (63 KB) | 224 | 346 | 21 | 95 | 39 | 135 |
| 530 (250 KB) | 283 | 502 | 73 | 223 | 134 | 296 |

A pays about 60 to 150 us more per request: instantiate, `init`, the JSPI wrappers and the first touch of fresh memory pages (stack and heap). The copy of B is small next to that up to 256 KB. With 64 tasks waiting, the copies (16 MB at depth 530) leave the CPU cache, so B per request doubles, but it stays below A.

### Latency and throughput (workerd)

| Variant | Depth | Copy KB | Conc | p50 ms | p99 ms | req/s | Errors+bad | Peak held copies KB | wasm memory MB |
|---|---|---|---|---|---|---|---|---|---|
| JS only | - | - | 1 | 9.22 | 10.92 | 108 | 0 | - | - |
| JS only | - | - | 16 | 9.65 | 18.32 | 1599 | 0 | - | - |
| JS only | - | - | 64 | 15.7 | 125.14 | 3499 | 0 | - | - |
| A | 0 | - | 1 | 10 | 13.53 | 97 | 0 | - | 1.3 |
| A | 0 | - | 16 | 15.19 | 26.93 | 1010 | 0 | - | 1.3 |
| A | 0 | - | 64 | 48.94 | 74.05 | 1303 | 0 | - | 1.3 |
| A | 30 | - | 1 | 10.07 | 13.87 | 97 | 0 | - | 1.3 |
| A | 30 | - | 16 | 14.33 | 28.65 | 1056 | 0 | - | 1.3 |
| A | 30 | - | 64 | 49.33 | 102.76 | 1128 | 0 | - | 1.3 |
| A | 130 | - | 1 | 10.05 | 14.5 | 97 | 0 | - | 1.3 |
| A | 130 | - | 16 | 13.75 | 28.04 | 1079 | 0 | - | 1.3 |
| A | 130 | - | 64 | 45.59 | 126.68 | 1278 | 0 | - | 1.3 |
| A | 530 | - | 1 | 10.01 | 15.3 | 96 | 0 | - | 1.4 |
| A | 530 | - | 16 | 15.69 | 32.9 | 936 | 0 | - | 1.4 |
| A | 530 | - | 64 | 55.56 | 90.75 | 1134 | 0 | - | 1.4 |
| B | 0 | 2 | 1 | 9.64 | 18.15 | 100 | 0 | 2 | 3.6 |
| B | 0 | 2 | 16 | 11.17 | 21.91 | 1326 | 0 | 28 | 3.7 |
| B | 0 | 2 | 64 | 28.07 | 75.19 | 2116 | 0 | 112 | 5.6 |
| B | 30 | 16 | 1 | 9.63 | 11.68 | 103 | 0 | 16 | 5.6 |
| B | 30 | 16 | 16 | 10.91 | 33.8 | 1382 | 0 | 253 | 5.6 |
| B | 30 | 16 | 64 | 30.13 | 77.75 | 2009 | 0 | 1012 | 9.3 |
| B | 130 | 63 | 1 | 9.93 | 11.86 | 100 | 0 | 63 | 9.4 |
| B | 130 | 63 | 16 | 12.48 | 36.23 | 1193 | 0 | 1003 | 11.3 |
| B | 130 | 63 | 64 | 36.43 | 77.07 | 1660 | 0 | 4012 | 17.5 |
| B | 530 | 250 | 1 | 10.1 | 12.26 | 99 | 0 | 250 | 18.0 |
| B | 530 | 250 | 16 | 13.76 | 37.41 | 1080 | 0 | 4003 | 25.3 |
| B | 530 | 250 | 64 | 41.38 | 84.85 | 1456 | 0 | 16012 | 50.3 |

"Peak held copies" is the most stack bytes on the heap at one time (host counter `task_saved_peak`): concurrency x copy size. "wasm memory" is `memory.buffer.byteLength` of the one instance (B), or of one instance (A). B rows run in one process from small to large depth, so its memory is the high-water mark so far: wasm memory never shrinks.

### Instantiate cost and memory

| Measure | Real module (49 KB) | Padded module (2.1 MB, 2 MB data segment) |
|---|---|---|
| `new WebAssembly.Instance` in workerd (client wall time of 500 in one request), us | 28 / 35 / 36 | 516 / 531 / 639 |
| Same in Node, us | 35 to 58 | 480 to 870 |
| Memory per instance (A) | 1.3 MB (1 MB stack + data + about 300 KB heap) | 3.4 MB |

| workerd RSS, MB | Start | After warmup | End of all runs |
|---|---|---|---|
| JS only | 59 | 92 | 372 |
| A | 58 | 101 | 260 to 433 (after 1000 instantiations in `/inst`) |
| B | 58 | 110 | 384 |

RSS grows in all three, the JS-only baseline too: it is mostly V8 heap that the GC does not give back under load, not wasm.

### Leak test (10000 requests, concurrency 16, depth 50)

| Variant | Trap rate | Traps | Errors+bad | Live heap bytes before -> after | wasm memory MB | RSS MB |
|---|---|---|---|---|---|---|
| A | 1 % | 105 | 0 | instance dropped | 1.3 per instance | 91 -> 227 |
| A | 0 | 0 | 0 | instance dropped | 1.3 per instance | 91 -> 216 |
| B | 1 % | 101 | 0 | 0 -> 6,147,264 (61 KB per trap) | 3.5 -> 9.5 | 93 -> 386 |
| B | 0 | 0 | 0 | 0 -> 0 | 3.6 -> 3.6 | 95 -> 382 |

A trap makes the request answer 500. B recovers with `task_abort` (stack pointer back to TOP, canary written again); the other waiting tasks finish with good bodies. This run was before owner tags: all heap that the trapped task held stayed allocated in B. In A it goes with the instance.

### Owner tags (2026-10-13, Node, `owner.mjs`, `track_live=false`, 3 runs)

Each live span keeps the id of the task that allocated it in the free-list word (`@4`, not used while the span is live). After a clean trap (Roc `crash`, canary, out of memory), `task_abort` walks the spans and frees those of the dead task. Any other trap returns -1: retire the instance.

| Item | Tags off | Tags on |
|---|---|---|
| alloc + free pair (24 B to 20 KB) | 2.6 to 3.2 ns | +0.2 to 0.7 ns |
| Whole request (depth 30, 200 items), median of 7 | 200.6 to 203.5 us | -0.4 to +4 us, inside the noise (spread 193 to 280) |
| Memory | | 0 |

Heap walk per trap (a task with no spans, so this is the walk alone):

| Live spans | Span size | Heap MB | us | ns per span |
|---|---|---|---|---|
| 1,000 | 24 B | 1.4 | 1.5 | 1.5 |
| 10,000 | 24 B | 1.8 | 13 | 1.3 |
| 65,536 | 24 B | 4.3 | 68 | 1.0 |
| 10,000 | 1000 B | 14.1 | 140 | 14 |
| 65,536 | 200 B | 30.1 | 994 | 15 |

Correctness (`node-test.mjs`: 200 requests at once with 4 traps, then 200 more on the same instance):

| Build | Bytes freed | Live bytes at the end | Bad bodies | Result |
|---|---|---|---|---|
| Tags on | 237,632 | 0 | 0 | pass |
| `-Downer_tag=false` | 0 | 237,632 | 0 | fail |
| Tags on, `roc_crashed` with a plain trap (not clean) | 0 (`task_abort` returns -1, 4 times) | 237,632 | 0 | fail |

Two bugs found on the way, both fixed:

| Bug | Fix |
|---|---|
| JS can call `js_alloc` for a waiting task after a trap, before `task_abort`. The block got the dead task's id and was freed while in use. | `js_alloc` allocates with owner 0; the task adopts the block at the resume (`bytesFrom`) or at `handle`. |
| With the free inside it, `task_abort` got a shadow-stack frame. Its epilogue wrote the old stack pointer back after `setSP`, so the next resume trapped at the `waitEnd` check. | The free runs in `abortFree`, called before `setSP`; `task_abort` has no frame. |

## Findings

| Finding | Detail |
|---|---|
| Copy cost is small | Up to 64 KB per wait: under 2 us. 256 KB: about 5 to 7 us. A realistic handler (480 B per Roc call level) needs 130 nested calls for 64 KB |
| Copy memory is concurrency x depth | 64 waiting tasks at 250 KB hold 16 MB. The wasm memory keeps its high-water mark (50 MB here), and on Cloudflare the isolate limit is 128 MB |
| A costs more CPU per request | About 60 to 150 us per request for the 49 KB module, 500 to 800 us for instantiate alone with a 2 MB data segment. Its memory is a fresh 1.3 MB (mostly the 1 MB stack) per request in flight |
| Throughput | No correctness errors in any run (0 bad bodies over 405,000 measured requests and 40,000 leak test requests). At concurrency 64, B serves 1.3 to 1.8x the req/s of A. The JS-only floor shows that workerd and the load generator cost most of the CPU |
| Leak on trap in B | About 61 KB per trap (the heap of the task) for this handler. Fixed with owner tags (see above): 0 leak after a clean trap, for about 0.3 ns per allocation and a walk of about 1 ms per trap at 30 MB |
| JSPI with Roc wasm | No problems found: `WebAssembly.Suspending` on the one hosted import and `WebAssembly.promising(handle)` work with the Roc `--target=wasm32` reactor output. The canary and `task_abort` work. The results on this page are from nightly 10-09, which links data-first (data below the stack, see `../PLAN.md` problem 1). From nightly 10-11 the layout is stack-first, the LLD 22 default |
| workerd clock | `performance.now()` does not advance inside a request (Spectre mitigation), so instantiate cost is client wall time of a loop of 500 |
| Check of the check | With the copy turned off in B (`set_copy(0)`, 64 requests at once, depth 50), 24 of 64 requests trap (the shared stack is overwritten). With the copy on: 0. `bench.mjs` counts a trap as an error |

## Edge (Q13, 2026-10-14, short test, not a full bench)

`bench/deploy.sh` deploys `talon-bench-echo` and `talon-bench-{a,b,j}` (the setup of `config-*.capnp`). `bench/deploy.sh delete` removes them. `EDGE=<account>.workers.dev node bench/edge.mjs [n]` runs the load and joins the server CPU and wall time from `wrangler tail`. Tail drops events, so its numbers are a sample. Account: free plan (10 ms CPU per request), colo TBS.

| Variant | Concurrency 1 | Concurrency 16 | Concurrency 64 |
| --- | --- | --- | --- |
| JS only (50 requests) | 0 errors | 0 errors | 0 errors |
| B, depth 30 (50 requests) | 0 errors, 0 bad | 0 errors, 0 bad | 0 errors, 0 bad |
| A, depth 30 (200 requests) | 0 errors, CPU about 6 ms | 179 `exceededCpu` | 199 `exceededCpu` |

| Measure | Edge | Local workerd |
| --- | --- | --- |
| CPU per request, A | about 6 ms | about 0.3 ms |
| `new WebAssembly.Instance` + `init`, real module | about 0.7 ms | 0.03 ms |

JSPI works on the edge. B is correct under concurrency, and A does not fit the free plan CPU limit.
