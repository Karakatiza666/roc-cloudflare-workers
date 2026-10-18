# JSPI concurrency bench

Question: a Roc wasm32 app with a Zig host serves concurrent requests that wait on async JS calls (JSPI). Which model is better in workerd?

| Variant | Model | Cost of a wait |
|---|---|---|
| A | Removed 2026-10-16: stack-first is guaranteed by the compiler. (the platform has no fallback; the measured rows below are history.) One precompiled `WebAssembly.Module`. Each request makes `new WebAssembly.Instance`, calls `handle` through `WebAssembly.promising` | None. One instance runs one request |
| B | One shared instance for all requests | A wait copies the used shadow stack `[sp, TOP)` to the heap and sets `__stack_pointer` to TOP. The resume copies it back to the same addresses (`../host/host.zig`) |
| JS only | No wasm. The same two waits and body, in JS | Floor of workerd and the load generator |

## Files

| File | Content |
|---|---|
| `../host/host.zig`, `../host/cbor.zig`, `../host/cbor_test.zig` | Host. `waitBegin`/`waitEnd` and `getSP`/`setSP` (copy), the bridge (`roc_await`, `roc_call`, `roc_native`: encode the program, `js_await`/`js_call`, decode the result, PLAN.md 8a), `handle`, `task_abort`, `copy_bench`, counters. `cbor.zig`: the CBOR profile over the glue types (API.md 5.1). `cbor_test.zig`: its native tests (HD5, HD6, HD7) |
| `../hostlib/` | Allocator, canary, Roc callbacks |
| `../platform/main.roc` and the modules of `../platform/` | Production platform: `requires { event! : Worker.Event => Worker.Outcome }` (PLAN.md 8b), the modules `Js` and `Io` (API.md 5, 6), `Native` (8e), `Worker`, `Request`, `Response`, `Body`, `Ctx` (8b) and the payload types of phase B (`Queue`, `Email`, `Object`, `WebSocket`), `Entry` (not exposed: the event as `Js` to `Worker.Event`, and the outcome back), the hosted functions `Js.host_await!` and `Js.host_call!` (apps use `Js.await!` and `Js.call!`) and `Host.native!` (not exposed), the production exports (PLAN.md 7a). `Method` and `Header` come from `roc-lang/http` (a package URL) |
| `platform/` | Bench platform: the same files with more exports (the test exports). The bench apps use it. `build.sh` builds its host with `zig build -Dbench=true` into `platform/targets/` (ignored) |
| `exports-test.mjs` | PLAN.md 7a: the two headers are equal but for `exports:`, the production build (`out/app_prod.wasm`, made from `app.roc` by `build.sh`) has the production exports and no bench export, and it serves requests with the runner of `../js/` |
| `app.roc` | `event!`: the request text is the body of a `Fetch` event, and the answer is the body of `Respond` (8b; all bench apps do the same). `worker.js` sends the text in the header `x-bench-text` (no body, so no wait before the work). A body of `makeHandler` is a stream since 10a: `app.roc` reads it with one wait more (`req.text!`, `handler-test.mjs`, `context-test.mjs`). Handler: 200 records to JSON (about 300 KB of heap), recursion `depth` levels with a kept value per level, two waits (fetch: 5 ms, db: 1 ms), body with the request id and a stack checksum. Each wait is `Js.await!` of a program that calls `ops.fetch` or `ops.db` with the roots `env`, `ctx`, `event` as the last arguments (`effect!`) |
| `../js/index.js`, `../js/events.js`, `../js/options.js`, `../js/runner.js`, `../js/wait.js`, `../js/host.js`, `../js/tasks.js`, `../js/budget.js`, `../js/bridge.js`, `../js/program.js`, `../js/helpers.js`, `../js/values.js`, `../js/cbor.js` | The JS shim (PLAN.md 9a, 8a). `makeHandler(module, opts)` checks the options (`ops`: the JS functions of the app, `pinLimit`, `other`: handler names for the event `Other`) and gives a subclass of `WorkerEntrypoint` with `fetch`, `scheduled` and the `other` methods (8b). `events.js` makes the events of API.md 10.1 (the request body as a stream, a ref of the task: 10a) and the `Response` of an outcome. `helpers.js` also has the stream helpers of `Body` (`readUpTo`, `chunk`, `sha256`, `transform`, `writer`, `close`) and of `Ctx` (`respond`, `passThrough`, `spawn`). The runner starts at the first event (workerd forbids random values at global scope). `makeRunner(module, opts)` is the runner: the `js_await` and `js_call` imports (`bridge.js`), the program interpreter (`program.js`), the root `pf` and the pin table (`helpers.js`), the CBOR profile (`values.js`, `cbor.js`), the task table (with the context and the ref table of each task, 9b), the memory budget. A module that is not stack-first throws at the first instance (no fallback, 2026-10-16) |
| `core.js`, `ops.js`, `check.js` | Test helpers. `core.js` re-exports the runner and the host readers of `../js/` for the Node tests. Its `makeRunner(module, io, opts)` turns the `io(kind, a, b, context)` of a test into the ops `fetch` and `db` of the bench apps (`ops.js`: the role of the old wait kinds 1 and 2), and its `run(text)` sends the text as a `Fetch` event and gives the body of `Respond` as `body` (8b). `eventBlock` and `outcomeBody` do the same for a test that calls `handle` itself. `check.js` has `expected` and `check` (the body that the bench app must give), `benchEvent` and `benchBody`. `worker.js` imports `check.js` only |
| `../conformance/` | PLAN.md 8c: the conformance app (`conformance/app.roc`, built by `build.sh` to `out/conformance.wasm`) in Miniflare, `run.mjs`, `reverts.mjs`, `must-not-compile.sh` (`conformance/README.md`). Wave 1: `Http`, `Env`, `Secret`, `Time`, `Log`, `RateLimit`. `R2Routes.roc`, `CacheRoutes.roc` and `checks/r2.mjs`, `checks/cache.mjs`: `R2` (with multipart) and `Cache` on the local R2 and Cache API of Miniflare, and the 10a test with a 50 MB object (`/__mem` of `worker.js` gives wasm memory). `../research/r2-cache-shapes/`: the shapes that Miniflare gives (probes). `D1Routes.roc`, `MemoRoutes.roc`, `PinRoutes.roc` and their checks: `D1` and `Sql` on the local D1 of Miniflare (with the constraint kinds of 8d), `Memo`, and the pin table (`Io.pin!`). `x-awaits` and `x-calls` of `worker.js`: the crossings of a request (`stats.crossings` of the runner). |
| `handler-test.mjs` | PLAN.md 9a: an instance of the class of `makeHandler` serves requests, an unknown option and a bad value throw at `makeHandler` time (also the removed `variant`, `noFallback` and `queueLimit`), `resumeCheck: "off"` throws on the production build and works on the bench build |
| `context-test.mjs`, `context-workerd.mjs` | PLAN.md 9b: requests at the same time with different headers. Each effect gets the roots `env`, `ctx` and `event` of its task (8a; was the task id) and sees the headers, `env`, `ctx` and request of its own task. `context-workerd.mjs` runs `worker.js` with `config-b.capnp`. The echo service answers with the header `x-ctx-id` when it is set |
| `app_deep.roc`, `overflow-test.mjs` | Stack overflow test: recursion with a wide record per level, with and without an allocation per level |
| `layout-test.mjs`, `fixtures/data-first-10-09.wasm` | A module that is not stack-first fails loudly (PLAN.md 1b): `makeHandler` and `makeRunner` throw at the first instance, with the layout and `check-layout.mjs` in the message. The fixture is `app_strloop.roc` built with nightly 10-09 (data-first), by `ROC=<10-09 roc> OUT=<dir> bench/build.sh` (that build now fails at the layout check, after the files are written) |
| `oneinstance-test.mjs` | One instance per isolate (PLAN.md 4a): 1,000 requests with 1 % unclean traps, never more than 1 instance with a task, 0 bad bodies |
| `app_wait.roc`, `cpu-test.mjs` | CPU flags of workerd (PLAN.md 5a to 5c): the exported globals, the signal (clean trap with cause "cpu"), the terminated flag (replace). `app_wait.roc` has one wait (`Js.await!([])`, an empty program) and no allocation |
| `app_strloop.roc`, `strloop-test.mjs` | Bug B5 (PLAN.md 6e): a string that grows in a loop. Wasm memory must stay under 6 MB |
| `alloc-test.sh`, `alloc_driver.zig`, `dfree.mjs`, `fmark.mjs`, `reserve.mjs`, `adopt.mjs`, `sumjs.mjs` | Allocator tests (PLAN.md 6e) on a driver built from `../hostlib/`: double free, free after the page went to another task, a live block with the free mark, the page reserve at the memory cap, adopted JS blocks at `freeOwner` and in `sumTask` |
| `../js/budget.js`, `budget-test.mjs`, `grow.mjs`, `budget-workerd.mjs`, `config-m.capnp` | The memory budget (PLAN.md 4b to 4e): the JS budget and its options, `js_grow` and the pressure steps in Node, the allocator driver that asks JS (`grow.mjs`, built by `alloc-test.sh`), and the dropped instance that counts until the callback in workerd |
| `events-test.mjs`, `idle-test.mjs`, `counters.mjs` | Log lines and counters (PLAN.md 4g, M11: one line and one counter for each event, and a trap in `task_cancel` is an alarm), the leak counter and the idle reset in the app (4h, 4j, and the end of `set_suspect` at a passed idle check), and the H3 counters and the idle reset against a manual walk of the unit tables on the allocator drivers (`counters.mjs`, built and run by `alloc-test.sh`) |
| `app_bridge.roc`, `bridge-test.mjs`, `bridge-reverts.mjs`, `bridge-workerd.mjs`, `bridge-worker.js`, `config-bridge.capnp` | The bridge (PLAN.md 8a): refs (RS1), programs, `Par`, `Race`, OP7, `pf` helpers, pins with a `CryptoKey`, `Packed` rows read by `Cbor.parse` (the package `roc-cbor` 0.1.0, the release of the platform; it was `bench/Cbor.roc`, a copy of `../research/api-probe/cbor/Cbor.roc`, until 8c), status 4, refs after 10,000 tasks with traps and cancels, HD3, HD6. `bridge-reverts.mjs` breaks one JS rule at a time in a copy of `../js/` and checks that its test fails. `bridge-workerd.mjs` runs the main tests in workerd (port 8134) |
| `app_native.roc`, `native-test.mjs`, `native-reverts.mjs` | `Native` (PLAN.md 8e): decode of package archives against `zstd -d`, the output limit and its memory, BLAKE3 and SHA-256 in chunks against the references of `../research/native/data/`, the zstd stream, handle errors, a handle of another task (`native_reown`, bench only), handles at the end, trap and cancel of a task, status 4 (OOM) at each allocation, and a deep recursion that calls `zstd_decode!` (the depth where it traps). `native-reverts.mjs` edits the Zig source one rule at a time, builds, runs the test and restores the file |
| `app_events.roc`, `entry-test.mjs`, `entry-workerd.mjs`, `entry-reverts.mjs`, `entry-worker.js`, `events-worker.js`, `config-entry.capnp`, `cf-node.mjs`, `cf-workers-stub.mjs` | The events (PLAN.md 8b, first half): the class of `makeHandler` (a `WorkerEntrypoint` subclass), a binary body, 100 headers, 404, JSON, the cron rules (cron and `time_ms`, `Err`, `no_retry!`, no `scheduled!`), `other` (`queue`), `Unhandled`, `Failed`, the crash text in the log line, `Request.Cf`. `entry-workerd.mjs` runs workerd with `--experimental` (port 8135): `entry-worker.js` serves `/cdn-cgi/local/scheduled` as Miniflare does and sends a queue event. `entry-reverts.mjs` makes each revert, runs the tests and restores the file. `cf-node.mjs` gives Node the stand-in `cf-workers-stub.mjs` for `cloudflare:workers` |
| `app_stream.roc`, `stream-test.mjs`, `stream-workerd.mjs`, `stream-reverts.mjs`, `stream-worker.js`, `config-stream.capnp` | Streams and the context of a task (PLAN.md 8b second half, 9c, 10a, 10b). A 50 MB request body back as the response body, the first chunk and a 1 KB limit of a 50 MB body: wasm memory grows by less than 1 MB. `tee!`, `sha256!`, `compress!` and `decompress!` (Node `zlib` as the reference). `Ctx.respond!` (the work after it, a second call, the 30 s limit at 100 ms, `InvalidState` in a cron run, `BodyErr` for a read of the request body after it in workerd), `Ctx.pass_through!`, `Body.writer!` (the first chunk before the second, the limit at `close!`, a cancel of the stream), `Ctx.wait_until!` (the promise in `ctx.waitUntil`, the context until it settles, the `waitUntil` limit, the log rule), the client that goes away in workerd (`request.signal`). Port 8136. `stream-reverts.mjs` makes each revert (18), runs both tests and restores the file |
| `wait-test.mjs`, `trapclean-test.mjs`, `tasktable-test.mjs` | The wait import never rejects (2b), TRAP_CLEAN (2d), the task table (2c). Since 8a they use `makeBridge` of `../js/bridge.js`; tasktable part 2 aims `fail_alloc_at` with `alloc_count` |
| `cbor-js-test.mjs`, `cbor-js-reverts.mjs`, `cbor-wasm-test.mjs`, `hd4-test.mjs`, `hd4/oracle.roc`, `jsgen.js`, `program-test.mjs` | The CBOR profile (API.md 5): the JS codec and its revert checks, the Zig codec in the wasm32 host (HD5 corpus, HD6, same bytes as JS), HD4 (the Zig decoder against the Roc oracle; the inputs go to `hd4/*.bin`, ignored), the seeded value generator, the program interpreter and the result block |
| `sha256-bench.mjs` | PLAN.md 8c (the measure for 8g): `Crypto.SHA256.hash` in wasm (the route `/webcrypto/sha256` of `../conformance/WebCryptoRoutes.roc`, run by `makeHandler` in Node) against `crypto.subtle.digest`, for 1 KB to 1 MB. `node bench/sha256-bench.mjs bench/out/conformance.wasm` |
| `8g/`, `8g-cbor-field/`, `8g-cbor-first/` | PLAN.md 8g, the measures of one crossing, D1 reads, `Cbor.parse` and SHA-256 in the platform. `8g/app.roc`: the measure app (bench platform): each route runs one operation `n` times in one request. `8g/run-node.mjs`, `8g/run-mf.mjs` (Miniflare, local D1), `8g/run-edge.mjs` (the deployed Worker, for 11c), `8g/run-variants.mjs` (host build variants), `8g/lib.mjs` (the method), `8g/parts.js` (the parts of a crossing, against the wasm exports), `8g/worker.js`, `8g/summarize.mjs`, `8g/build.sh` and `8g/host-build/` (the host with `-Dopt` and `-Dtrack_live`), `8g/deploy-edge.sh`, `8g/results/` (the tables of the runs below). `8g-cbor-field/` and `8g-cbor-first/`: copies of `roc-cbor` 0.1.0 whose `parse_record_field` gives `Field` (never edit or publish `roc-cbor`). Sections "Step 8g" below. |
| `test-all.sh` | Builds everything and runs all tests with `timeout 600`: one line for each, exit 1 when one fails. Env: `ZIG`, `WORKERD` |
| `check-layout.mjs` | Reads a linked wasm: STACK-FIRST, DATA-FIRST or UNKNOWN (exit 0, 1, 2). `build.sh` runs it on its outputs and fails on a result that is not STACK-FIRST |
| `get-roc.sh`, `ci-layout.sh`, `../compat/last-stack-first-nightly` | Nightly download, the CI check of one nightly (`../.github/workflows/nightly-layout.yml`), the pinned nightly. A nightly that is not stack-first fails the job: it cannot be used at all, the platform has no fallback |
| `worker.js`, `echo.js`, `config-{b,j,m,s}.capnp` | workerd worker (it uses `makeHandler`, and gives the class a new request with the text of the URL as its body and the signal of the client request; its ops `fetch` and `db` get `env` and the request as arguments, the roots of the task), echo service binding, one config per variant (`b`: the platform, `j`: no wasm). The configs list the `../js/` modules as `js/*.js` |
| `bench.mjs` | Load generator (Node fetch, concurrency pool) and driver: fresh workerd per variant (`b`, `j`) and rep |
| `owner.mjs` | Cost of owner tags: alloc + free, heap walk per trap, whole request. Two builds, tags on and off (the option `owner_tag` is removed, 2026-10-17: it runs only on two wasm files of an older tree) |
| `micro.mjs` | CPU cost in Node with a real clock: instantiate, copy work alone, per request by depth |
| `summarize.mjs` | Markdown tables from the `bench.mjs` output |

## Reproduce

```sh
ZIG=<zig 0.17> bench/build.sh   # roc: the nightly in compat/ (ROC= to override)
node bench/node-test.mjs bench/out/app.wasm                      # smoke test
node bench/overflow-test.mjs bench/out/app_deep.wasm             # stack overflow
node bench/oneinstance-test.mjs bench/out/app.wasm               # one instance (4a)
node bench/layout-test.mjs bench/out/app.wasm                    # a data-first module throws (1b)
node bench/cpu-test.mjs                                          # CPU flags (5a to 5c)
node bench/strloop-test.mjs bench/out/app_strloop.wasm           # string loop (B5)
ZIG=<zig 0.17> bench/alloc-test.sh                               # allocator tests
bench/ci-layout.sh <nightly tag>                                 # what CI runs for a new nightly
WORKERD=<workerd 2026-10-12> node bench/bench.mjs 3 5000 > .cache/results/bench.jsonl
WORKERD=<workerd> node bench/bench.mjs leak 10000 0.01 > .cache/results/leak.jsonl
node bench/summarize.mjs .cache/results/bench.jsonl .cache/results/leak.jsonl
node bench/micro.mjs bench/out/app.wasm bench/out/app_pad.wasm
ITEMS=0 node bench/micro.mjs bench/out/app.wasm bench/out/app_pad.wasm   # no JSON work
# Owner tags (2026-10-13): `-Downer_tag=false` was removed 2026-10-17 (PLAN.md 8g P3), so `owner.mjs` has no second build to compare
```

`build.sh` sets `ROC_CACHE_DIR`, `XDG_CACHE_HOME` and `ZIG_GLOBAL_CACHE_DIR` to `.cache/` (ignored). Request: `GET /h?id=&trap=0|1&depth=`. Depth to copy size: 1.8 KB + 480 B per level (0: 1.8 KB, 30: 16 KB, 130: 63 KB, 530: 250 KB).

## Results (2026-10-13, 24 cores, a parallel job loaded the machine: load average 5 to 10)

Removed 2026-10-16: stack-first is guaranteed by the compiler. Variant A (and the instantiate cost and the `/inst` path) is removed from the platform and the bench. The rows of A in this section are old measurements: `bench.mjs`, `edge.mjs` and `summarize.mjs` no longer run it.

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

Removed 2026-10-17 (PLAN.md 8g, P3): the build option `owner_tag` (`-Downer_tag=false`) is gone. No source of `hostlib/` or `host/` read it, so the hosts with and without it were the same file (the default `small` mode: `platform/targets/wasm32/host.wasm` and `bench/platform/targets/wasm32/host.wasm` are byte equal before and after the removal). The tags themselves stay in the allocator and cannot be switched off. This section is the measure of 2026-10-13, with the allocator of that day (`owner.mjs` needs two builds that differ in the tags, so it does not run on the tree today).

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

## Error texts of `fetch` (PLAN.md 8d, local, 2026-10-16)

The docs do not give the JS `name` and `message` of a failed `fetch`. These are the texts that `conformance/run.mjs` got (Miniflare 5.20261012.0-beta, workerd 2026-10-12), and the tag of `Http` (MODULES.md MC9). The edge run is 11c.

| Request | JS `name` | JS `message` | Tag |
| --- | --- | --- | --- |
| A closed port: `http://127.0.0.1:1/` | `Error` | `Network connection lost.` | `Network` |
| A host that does not exist: `http://no-such-host.invalid/` | `Error` | `internal error; reference = <id>` (a new id each time) | `Network` |
| `"not a url"` | `TypeError` | `Invalid URL: not a url` | `HttpErr` |
| `send_with!` with `timeout_ms` 100 on an answer after 2 s | `TimeoutError` | `The operation was aborted due to timeout` | `Network` |

## SHA-256 in wasm against `crypto.subtle.digest` (PLAN.md 8c, Node 26, 2026-10-16)

`node bench/sha256-bench.mjs bench/out/conformance.wasm`: `n` hashes of one buffer size in one request of `makeHandler` (less a request with no hash), and `digest` in the same process (one `await` each). The digest of the last buffer is compared with Node `crypto`. Median of 5, three runs of the script, load average 3 to 5 (the numbers move by about 20 %).

| Size | `Crypto.SHA256.hash` in wasm (us) | `crypto.subtle.digest` (us) |
| --- | --- | --- |
| 1 KB | 2.5 | 6 to 8.4 |
| 4 KB | 9.1 to 11.6 | 7.4 to 11.3 |
| 16 KB | 35.8 to 37.2 | 13.7 to 14.9 |
| 64 KB | 143.6 to 151.9 | 35.9 to 43 |
| 1 MB | 2,329 to 2,808 | 507 to 793 |

`digest` here has no copy from wasm memory, no bridge crossing and no JSPI wait. In the platform it has all three, so the size where it wins is higher (8g).

## Step 8g: crossing, D1 reads, `Cbor.parse`, SHA-256 in the platform (PLAN.md 8g, local, 2026-10-17)

Setup of all tables of this section:

| Item | Value |
|---|---|
| Machine | AMD Ryzen AI 9 HX 370, 24 threads, 91 GB, governor `powersave`. Load average 2 to 3 (other jobs ran) |
| Node | v26.7.0 (V8 14.6): `makeHandler` of `js/` with `bench/cf-node.mjs`, the wasm of the platform (bench host) |
| workerd | 2026-10-12 in Miniflare 5.20261012.0-beta, local D1. The clock of workerd moves in steps of 1 ms: the harness times the whole request from Node |
| Roc, Zig | nightly 2026-10-12 (`--opt=speed`, wasm32), Zig 0.17 (host: optimize mode `small`) |
| Shim options | the defaults, with `heapCheckEvery: 0` and `heapCheckWhenIdle: false` (no global check inside a timed request). `resumeCheck` is `always` (the default) except where a table says `off` |
| Method (`8g/lib.mjs`) | A route runs one operation `n` times in one request, with an input that changes (so the compiler cannot hoist it). The cost of one operation is (time of a request with n = N less time of a request with n = 0) / N, where N makes the request take about 100 ms. 9 rounds for each run, 3 runs (2 for the `off` tables): each cell is the median over the runs of the median of each run. The spread in a cell is the min and max over the runs |
| Fake D1 | In Node and for the `fake` rows in workerd the binding `DB` is a JS object (`prepare().bind().all()` and `raw()`) that gives the same 200 rows each time. So a case measures the platform (shim, host, Roc), not SQLite. The 200 rows have 8 columns (`grp`, `version`, `hash`, `url`, `published_at`, `log_index`, `yanked`, `provenance`), 44 KB as a CBOR tree and 56 KB as typed CBOR, the same rows as `research/api-probe/cbor/` |

Commands (the numbers are in `8g/results/*.md`, made by `8g/summarize.mjs` from the raw lines of 3 runs):

```sh
ZIG=<zig 0.17> bench/8g/build.sh                  # app-<variant>.wasm for the host variants; app.wasm is the default host
node bench/8g/run-node.mjs                        # env SECTIONS=cross,d1,parse,sha,parts  RESUME=always|off  ROUNDS=9  TARGET_MS=100
node bench/8g/run-mf.mjs                          # env SECTIONS=cross,d1,d1real,parse,sha,parts,clock, a wasm as the argument
RESUME=off SECTIONS=cross,sha node bench/8g/run-node.mjs
node bench/8g/run-variants.mjs                    # track_live and the optimize mode, Node
node bench/8g/summarize.mjs run1.txt run2.txt run3.txt
bench/8g/deploy-edge.sh && EDGE_URL=https://talon-bench-8g.<account>.workers.dev node bench/8g/run-edge.mjs   # 11c, not run yet
```

### One crossing (`/cross/<call|await>?k=`)

A program of `k` ops is `k` times `isFinite(i)` on the root `global`, one `Js.call!` or `Js.await!` for each crossing. `call` has no wait. `await` has one JSPI wait.

| Program | Node `call!` (us) | Node `await!` (us) | workerd `call!` (us) | workerd `await!` (us) |
|---|---|---|---|---|
| 0 ops | 0.36 | 1.81 | 0.50 | 2.00 |
| 1 op | 1.20 | 2.57 | 1.35 | 3.00 |
| 4 ops | 2.80 | 4.25 | 3.11 | 4.88 |
| 16 ops | 8.98 | 10.5 | 9.66 | 12.2 |

The 3 runs differ by less than 5 % in each cell, except `await!` in workerd (up to 16 % from the lowest to the highest run). Each op after the first costs 0.52 us (Node) and 0.55 us (workerd) in `call!`, and 0.53 and 0.61 us in `await!`. The wait costs 1.44 us (Node) and 1.50 us (workerd): `await!` less `call!` of the empty program. With `resumeCheck: "off"` the empty `await!` costs 1.28 us (Node) and 1.51 us (workerd), so the check at the resume costs 0.5 us for a task with a small memory (`bench/8g/results/*-off.md`).

The parts of one `call!` (Node, us; "other" is the rest: the size pass of `encodedSize`, the free of the tree, the loop, 0.36 us with no op):

| Part | 1 op | 4 ops | 16 ops | Where |
|---|---|---|---|---|
| Roc: `Js.program` makes the tree, then it is freed (`/cross/build`) | 0.17 | 0.48 | 1.71 | `platform/Js.roc` |
| Zig: encode the program (`cbor_echo` less `cbor_check`) | 0.18 | 0.49 | 1.88 | `host/host.zig:376` |
| JS: `fromJs` of the program | 0.20 | 0.67 | 2.43 | `js/bridge.js:85` |
| JS: run the ops (`runCall`) | 0.09 | 0.29 | 1.03 | `js/program.js` |
| JS: encode the result (`writeResult`) | 0.21 | 0.20 | 0.20 | `js/bridge.js` |
| Other, by difference | 0.36 | 0.68 | 1.73 | |
| Whole `call!` | 1.20 | 2.80 | 8.98 | |

workerd has the same parts within 20 % (`8g/results/mf-always.md`): 16 ops `call!` 9.66 us, of which Roc 1.80, Zig encode 2.08, JS decode 2.32, run 1.19, result 0.25.

### D1 reads: `D1.all!` (typed, `Packed` CBOR) against `D1.rows!` (`Js` tree, no types)

Fake D1, us for one call (one crossing with one wait), 9 rounds, 3 runs. The names are the routes `/d1/<name>`: `all` is `D1.all!` into `List(Row)`, `rows` is `D1.rows!`. The other routes are the same programs cut after one step (`8g/app.roc`: `d1_ops!`), so the cost of a step is a difference.

| Case | Node 20 rows | Node 200 rows | workerd 20 rows | workerd 200 rows |
|---|---|---|---|---|
| `D1.all!` (`all`) | 25.9 | 197.8 | 30.6 | 236.0 |
| `D1.rows!` (`rows`) | 17.8 | 115.1 | 19.7 | 127.0 |
| `all` / `rows` | 1.46 | 1.72 | 1.55 | 1.86 |
| `all_arrays`: `raw()`, `pf.pack`, `Cbor.parse` into tuples | 14.7 | 91.4 | 16.2 | 102.6 |
| `tree_typed`: `raw` tree, a hand-written match into `Row` | 17.1 | 111.3 | 19.0 | 121.2 |
| `obj_tree`: `all()` rows as objects in a `Js` tree, no match | 21.8 | 160.1 | 24.9 | 184.0 |

`D1.all_tuples!` in the platform (PLAN.md 8g, P1, built 2026-10-17: route `/d1/all_tuples`, `8g/results/node-p1-p2.md` and `mf-p1-p2.md`, 3 runs, the same fake D1). It is the public function that reads `raw()` and `pf.pack` into a `List` of tuples of 8 (`RowT`). The sanity of the harness checks that `all` and `all_tuples` give the same sum for 20 and 200 rows.

| Case | Node 20 rows | Node 200 rows | workerd 20 rows | workerd 200 rows |
|---|---|---|---|---|
| `D1.all!` into records (`all`) | 26.3 | 196 | 30.2 | 231.7 |
| `D1.all_tuples!` into tuples (`all_tuples`) | 14.7 | 91.4 | 16.4 | 102.3 |
| `all` / `all_tuples` | 1.79 | 2.14 | 1.84 | 2.26 |
| `D1.rows!` (`rows`, same runs) | 17.4 | 111.7 | 19.3 | 125.7 |
| `all_arrays` (the 8g program of before, same runs) | 14.8 | 89.3 | 16.2 | 101.4 |

The PLAN number (91 against 198 us in Node, 103 against 236 us in workerd, 2.2 and 2.3 times) is confirmed in the platform: 91.4 against 196 and 102.3 against 231.7. `all_tuples!` is equal to the hand-made program `all_arrays` (inside the spread), so the function adds nothing: the same ops, one `typed_tuples` call. It is also cheaper than `D1.rows!` (111.7 and 125.7 us), and it keeps the types.

The steps of 200 rows (Node, workerd), us:

| Step | `D1.all!` | `D1.rows!` |
|---|---|---|
| D1 call, result dropped (`js_only`, `raw_js_only`) | 4.4, 4.5 | 5.3, 5.2 |
| JS encode, copy back, Zig decode (`pack_only` less `js_only`, `raw_only` less `raw_js_only`) | 81.9, 97.4 | 99.6, 111.7 |
| Roc: `Cbor.parse` into records (`all` less `pack_only`), the match into `Sql.Rows` (`rows` less `raw_only`) | 111.5, 134.1 | 10.2, 10.1 |
| Whole call | 197.8, 236.0 | 115.1, 127.0 |

The decode of 200 rows, each part alone against the wasm exports (`8g/parts.js`, us for one call, Node, workerd; the clock of workerd has steps of 1 ms, so a part of workerd is read to about 2 us):

| Part | 20 rows | 200 rows |
|---|---|---|
| JS encode of the tree of arrays (`pf.limit`, `D1.rows!`), 44 KB | 6.4, 7.6 | 48.0, 60.6 |
| JS encode of the rows as typed CBOR (`pf.pack`, `D1.all!`), 56 KB | 9.4, 11.2 | 77.9, 97.7 |
| Zig decode of the tree into Roc values (`cbor_check`, 1,003 allocations for 200 rows) | 5.5, 5.9 | 51.3, 54.7 |
| Zig decode of `Packed` (one byte string: a copy into a `List(U8)`) | 0.11, 0.12 | 0.65, 0.67 |
| Roc `Cbor.parse` of the rows as records (`/parse/records`) | 11.0, 13.4 | 107.9, 130.2 |

Real D1 in Miniflare (`d1real` in `8g/results/mf-always.md`): one query takes 2.1 ms for 20 rows and 2.4 to 3.8 ms for 200 rows, and it moves by more than 20 % from one round to the next. That is 11 times (200 rows) to 70 times (20 rows) the whole shim part of the read, so the differences between the cases cannot be read there (for example `all` 2,681 us and `raw_only` 2,478 us for 200 rows). The fake D1 is the measure for 8g. With the local D1 the typed read of 200 rows (0.24 ms in workerd) is about 9 % of the 2.7 ms of the query.

### `Cbor.parse` of records against tuples, and the `Field` variant of `roc-cbor`

Roc only, in wasm (`/parse/<name>?rows=`): the bytes come from one crossing, then `n` parses of the same bytes (one byte of the first text changes before each parse, so it cannot be hoisted) and a sum that reads every field. `fold_only` is that sum alone, on a list that was parsed once. All routes use `parse_with(bytes, { fields: Snake, int_from_text: Bool.True })`, as `D1.all!` does (`platform/SqlRules.roc:35`).

| Case | Node 20 rows (us) | Node 200 rows (us) | workerd 20 rows | workerd 200 rows |
|---|---|---|---|---|
| Records `{ grp, version, ... }` (`records`) | 11.0 | 107.9 | 13.4 | 130.2 |
| Tuples of 8 (`tuples`) | 3.73 | 36.1 | 3.76 | 36.3 |
| Record matching (records less tuples) | 7.3 | 71.8 | 9.6 | 93.9 |
| Share of the record parse that is matching | 66 % | 67 % | 72 % | 72 % |
| `Field` variant, exact compare of the key bytes (`variant_field`) | 48.6 | 482 | 72.7 | 725 |
| `Field` variant, length and first byte only (`variant_first`, not correct, a bound) | 46.8 | 466 | 72.2 | 726 |
| The sum alone (`fold_only`) | 0.05 | 0.47 | 0.06 | 0.55 |

`8g-cbor-field/Cbor.roc` is `roc-cbor` 0.1.0 with `parse_record_field` that reads the head of the key, finds the field with `names.for_size(len)` and `FieldName.name`, and gives `Field({ field, rest })`. It makes no key `Str`. It passes the 78 `expect`s of the package (`roc test bench/8g-cbor-field/Cbor.roc`). `8g-cbor-first/Cbor.roc` compares only the length and the first byte: it also passes the 78 `expect`s, so it is a bound for the cost of the lookup, not a parser to use. Both are 4.3 to 5.6 times slower than the `TryField` path. The cause is not shown by the measure: the only way to get a `FieldName` is to walk the `Iter` of `FieldNames` (`for_size`, `iter`), and the walk costs more than the key `Str` and the name match of the derived parser that it replaces. The nightly has no lookup by bytes in `FieldNames`. The tuple parse is 3 times faster than the record parse in wasm, and it has no key at all.

The numbers here are lower than the native ones of API.md AQ5 (137 us records, 66 us tuples): the allocator of the host is cheaper than `malloc`.

### Cost of `track_live`, `owner_tag` (removed) and the optimize mode in the Zig tree decode

`8g/build.sh` built the bench host in 5 variants (`8g/host-build/build.zig` is `build.zig` with `-Dopt` and `-Dtrack_live`; its `default` host equals the host of the tree byte for byte). The variant `ot_off` (`-Downer_tag=false`) is removed with the option (2026-10-17, P3): the row below is the measure of 2026-10-17 before the removal. Node, 5 reps in rotating order, median (spread), us:

| Variant | Zig decode, 200 rows | Zig decode, 20 rows | `D1.rows!` 200 rows | `D1.all!` 200 rows | `host.wasm` (bytes) |
|---|---|---|---|---|---|
| `default` (small, `track_live` on) | 46.7 (46.5 to 46.8) | 5.01 | 108.4 | 196.2 | 1,286,847 |
| `tl_off` (`track_live=false`) | 45.5 (45.0 to 45.8) | 4.89 | 106.3 | 194.2 | 1,284,225 |
| `ot_off` (`track_live=false`, `owner_tag=false`) | 45.3 (45.1 to 45.9) | 4.87 | 105.6 | 194.2 | 1,284,225 |
| `fast` (optimize mode fast) | 37.9 (37.4 to 37.9) | 4.12 | 99.6 | 195.5 | 2,218,337 |
| `fast_tl_off` | 37.0 (36.9 to 37.2) | 4.05 | 98.3 | 196.3 | 2,209,661 |

| Finding | Number |
|---|---|
| `track_live` | 1.2 us of 46.7 us (2.6 %) for 1,003 allocations and frees: about 1.2 ns each |
| `owner_tag` | No effect. `host-ot_off.wasm` and `host-tl_off.wasm` are the same file (`cmp`). The option was in `build.zig:12` (removed 2026-10-17, P3) and no source of `hostlib/` or `host/` read it: the owner is the page table of the allocator (`hostlib/alloc.zig`, `taskOf`) and cannot be switched off. Only `research/traps/alloc_v0_walk.zig` read it |
| Optimize mode `fast` | The decode takes 19 % less (46.7 to 37.9 us), `D1.rows!` 8 % less, `D1.all!` no change (its time is in Roc). The host is 72 % larger |
| Native Zig (`research/api-probe/bench/decode.zig`, ReleaseFast, 3 runs on this machine) | 24 to 25 us for 200 rows (another decoder, one pass). The wasm decode in mode `small` is 1.9 times that, in mode `fast` 1.5 times |
| workerd (2 reps, steps of 2 us) | decode of 200 rows: `default` 54.7 and 54.7, `tl_off` 52.7 and 54.7, `fast` 44.9 and 46.9, `fast_tl_off` 44.9 and 46.9 |

The decode takes about 46 ns for each allocation, and the allocator is 3 ns of a pair (`alloc_bench`), so the time is in the check pass and the build pass over 44 KB, not in `track_live` or the owner.

### SHA-256: `Crypto.SHA256.hash` (builtin, in wasm) against `crypto.subtle.digest`, in the platform

The routes `/sha/<name>?size=`. `wasm`: the builtin on a `List(U8)` of wasm memory (the first byte changes each time). `digest`: `Js.await!` of `crypto.subtle.digest('SHA-256', Lit(Bytes(buffer)))` with the buffer from wasm memory (the whole path: encode in Zig, copy to a `Uint8Array`, one wait, digest). `digest_js`: the same with the buffer already in JS (`ops.lib.buf(size)`, a cached array): the digest and the wait. `copy_only`: `Lit(Bytes)` to `ops.lib.len`, one wait, no digest: the copy and the wait. The answer of `wasm` and of `digest` is checked to be the same hex. us for one hash, `resumeCheck: always`:

| Size | Node `wasm` | Node `digest` | Node `copy_only` | workerd `wasm` | workerd `digest` | workerd `digest_js` | workerd `copy_only` |
|---|---|---|---|---|---|---|---|
| 256 B | 0.72 | 13.0 | 3.26 | 0.85 | 5.59 | 6.04 | 3.34 |
| 1 KB | 2.34 | 10.0 | 3.46 | 2.72 | 6.11 | 6.48 | 3.65 |
| 2 KB | 4.47 | 9.59 | 3.54 | 5.35 | 6.70 | 6.91 | 3.80 |
| 4 KB | 8.75 | 12.2 | 3.85 | 10.3 | 7.90 | 7.68 | 4.01 |
| 8 KB | 17.3 | 14.0 | 4.41 | 20.5 | 10.1 | 9.42 | 4.63 |
| 16 KB | 34.3 | 18.9 | 6.05 | 40.8 | 14.5 | 12.9 | 5.74 |
| 64 KB | 137.6 | 48.6 | 12.4 | 161.3 | 39.8 | 34.3 | 11.5 |
| 256 KB | 546 | 160 | 52.1 | 645 | 142 | 121 | 34.3 |
| 1 MB | 2,181 | 638 | 224 | 2,607 | 560 | 461 | 137 |

| Result | Node | workerd |
|---|---|---|
| Size where `digest` is faster (the difference, linear between the two sizes that bracket it) | 6.0 KB (4 KB: `digest` 3.5 us slower, 8 KB: 3.3 us faster) | 2.7 KB (2 KB: 1.4 us slower, 4 KB: 2.4 us faster). With `resumeCheck: off`: 2.3 KB |
| Builtin speed | 480 MB/s | 400 MB/s |
| `digest` speed at 1 MB, with the copy and the wait | 1.6 GB/s | 1.9 GB/s |
| Fixed cost of `digest` (256 B, with the copy) | 13 us (Node uses a thread pool) | 5.6 us |
| Slope: builtin, `digest` | 2.1 and 0.6 us per KB | 2.5 and 0.5 us per KB |
| Share of the copy and the wait in `digest` at 1 MB | 35 % | 24 % |

`WebCrypto.sha256!` in the platform (PLAN.md 8g, P2, built 2026-10-17: route `/sha/pick`, `sha256_crossover_bytes = 2_700` at that time, 3 runs, us; the constant is 4_096 since 2026-10-17, see below):

| Size | workerd `wasm` | workerd `digest` | workerd `pick` | Node `wasm` | Node `digest` | Node `pick` |
|---|---|---|---|---|---|---|
| 256 B | 0.864 | 5.74 | 0.838 | 0.713 | 10.1 | 0.722 |
| 1 KB | 2.77 | 6.07 | 2.79 | 2.38 | 10.2 | 2.35 |
| 2 KB | 5.34 | 6.69 | 5.28 | 4.50 | 9.94 | 4.49 |
| 4 KB | 10.3 | 7.85 | 7.58 | 8.81 | 11.2 | 11.5 |
| 8 KB | 20.4 | 9.97 | 9.87 | 17.5 | 14.2 | 13.8 |
| 64 KB | 162.4 | 39.8 | 39.6 | 137.7 | 48.9 | 51.4 |
| 1 MB | 2,587 | 557 | 559 | 2,206 | 677 | 734 |

In workerd `pick` follows the faster of the two at each size (the check of the length costs nothing that shows): 1 MB 559 against 2,587 us (4.6 times), 64 KB 39.6 against 162.4 us. In Node the crossover is 6 KB, so between 2.7 and 6 KB `pick` takes `digest` where the builtin is faster (4 KB: 11.5 against 8.81 us). Node is for the tests only, so one constant is used. The constant is one line in `platform/WebCrypto.roc` (`sha256_crossover_bytes`). The edge run of 11c gave about 4 KB, and the production target is the edge, so the constant is 4_096 since 2026-10-17 (local workerd: the `pick` rows from 2.7 to 4 KB are then the builtin, which costs at most 2.7 us more at 4 KB: 10.3 against 7.6 us).

`resumeCheck: off` changes `digest` by 5 % to 10 % at 1 MB (workerd 560 to 536 us) and by 0.5 us for small sizes (`8g/results/*-off.md`). The builtin blocks the isolate while it runs, and `digest` is a wait: other tasks run during it. The edge numbers are on the 11c list (PLAN.md, "Status of step 8g").

### Step 8g on the edge (PLAN.md 11c, edge, 2026-10-17)

`edge/deploy-8g.sh` (the Worker `rocplat-test-8g`, a D1 database, no `cpu_ms`: the Free plan refuses it), then `CLOCK=0 ROUNDS=9 TARGET_MS=25 EDGE_URL=... node edge/run-8g.mjs` (`edge/run-8g.mjs` is `8g/run-edge.mjs` that skips `/__clock` and keeps going after a failed case). Run 1: `resumeCheck: always`, all sections. Run 2: `RESUME=off edge/deploy-8g.sh`, sections `cross` and `sha`. Raw: `edge/results/8g/`. Client in Tbilisi (colo `TBS`), D1 in `EEUR`.

Limits of these numbers: on the Free plan a request of 300 ms of CPU got the CPU signal (`trap cpu limit`) after earlier heavy requests, so each timed request is only about 25 ms. The network jitter is then large against the work: a case with `N` 2 to 10 or a negative `min` is not usable (marked "-"). Take the rest as plus or minus 20 %.

`/__clock`: a busy loop of 2 times 5e7 reads of the clock gives `error code: 1102` (the isolate is stopped for its CPU). So the clock does not move in a busy loop on the edge, and the client clock is the method.

One crossing (us, median of 9 rounds):

| Case | Edge, check at the resume | Edge, `resumeCheck: off` | workerd local |
| --- | --- | --- | --- |
| `call!` 1 op (k=1) | 3.0 | 3.2 | 1.35 |
| `call!` 4 ops | 7.2 | 7.0 | 3.11 |
| `call!` 16 ops | 24.2 | 21.5 | 9.66 |
| `await!` 0 ops | 4.1 | 2.6 | 2.00 |
| `await!` 1 op | 5.8 | 4.6 | 3.00 |
| `await!` 4 ops | 9.1 | 9.0 | 4.88 |
| `await!` 16 ops | 22.4 | 22.6 | 12.2 |

D1 reads with the fake `DB` (us for one read):

| Case | 20 rows | 200 rows | workerd local, 200 rows |
| --- | --- | --- | --- |
| `D1.all!` (typed) | 67.1 | 568 | 236.0 |
| `D1.rows!` (`Js` tree) | 45.2 | - | 127.0 |
| `all_arrays` (tuples, P1) | 41.5 | 257 | 103 |
| `pack_only` | 40.2 | 276 | |

Real D1 (`d1real`): one query takes 70 to 98 ms from the Worker in `TBS` to D1 in `EEUR` (20 rows 70 to 74 ms, 200 rows 85 to 98 ms, the same for each read form within the noise). The typed read (`all!` against `rows!`, about 0.3 ms for 200 rows) is under 1 % of a query.

`Cbor.parse` (us): records 200 rows 257, tuples 200 rows 75.6 (3.4 times; local workerd 130 and 36.3).

SHA-256 (us, run 1 and run 2):

| Size | `wasm` | `digest` | `digest_js` | `copy_only` |
| --- | --- | --- | --- | --- |
| 256 B | 1.5, 1.5 | 14.8, 10.5 | 15.8, 10.7 | 6.3, 5.5 |
| 1 KB | 4.6, 5.8 | 12.0, 12.7 | 12.3, 12.1 | 7.1, 6.4 |
| 2 KB | 9.1, 9.1 | 16.4, 12.6 | -, - | -, 8.1 |
| 4 KB | -, 19.5 | 19.6, 21.8 | 16.4, 13.8 | 12.1, 10.1 |
| 8 KB | 37.1, 38.0 | 28.0, 28.3 | 18.3, 20.5 | 14.4, 14.1 |
| 16 KB | 77.0, 77.5 | 50.7, - | 27.1, - | 22.2, - |
| 64 KB | 299, 319 | 132, 122 | 64.2, 59.2 | 77.2, 74.4 |
| 256 KB | 1,208, 1,250 | 406, 426 | 207, 179 | -, 255 |
| 1 MB | -, 5,207 | -, 1,447 | 723, 649 | 976, 700 |

CPU time from `wrangler tail` (`edge/probe-11c.mjs shacpu`, 3 requests each, whole ms): `sha/wasm?size=1048576&n=4` 19 to 21 ms, `sha/digest?...&n=4` 7 ms, `n=16` 22 to 31 ms, `n=0` 0 to 1 ms. So `digest` is CPU time of the request (cpuTime equals wallTime), and costs about 1.6 ms for 1 MB against 5 ms for the builtin.

| Result | Edge | workerd local |
| --- | --- | --- |
| Size where `digest` is faster | about 4 KB (2 KB: the builtin 9.1 against 12.6 to 16.4; 4 KB: equal; 8 KB: `digest` 28 against 37) | 2.7 KB |
| Builtin speed | about 210 MB/s (5.0 ms for 1 MB by `cpuTime`) | 400 MB/s |
| `digest` at 1 MB | 1.4 to 1.8 ms (wall), 1.6 ms (`cpuTime`) | 0.56 ms |
| A crossing, against local | about 2 times | |
| The check at the resume | `await!` 0 and 1 op: 1.2 to 1.5 us more with the check; 4 and 16 ops: no difference in the noise | 0.5 us |

## Edge texts and forms (PLAN.md 11c, edge, 2026-10-17)

The texts that differ from the local tables above, or that local tests do not have. Source: `edge/results/` (the section "Status of the edge run" of PLAN.md).

| Call | Edge | Local |
| --- | --- | --- |
| `fetch` of a closed port (`http://127.0.0.1:1/`) | a response: 403, body `error code: 1003` (so `Http` gives `Ok`) | `Error: Network connection lost.` (`Network`) |
| `fetch` of a host that does not exist | a response: 530, body `error code: 1016` | `Error: internal error; reference = <id>` |
| `fetch` of `https://10.255.255.1/` | a response: 403 `error code: 1003` | |
| `fetch` of a Worker on workers.dev of the same account | 404 `error code: 1042`, unless the flag `global_fetch_strictly_public` | |
| `Queue.send_batch!` of 101 messages | `batch message count of 101 exceeds limit of 100 (10206)` | `Unknown Internal Error (15000)` |
| `Queue.send_with!` with `delay_ms` 86,401,000 | `Invalid message delay: Expected a number between 0 and 86400, received 86401 (10210)` | |
| `Workflows` `create()` with no id | the id `cf_<64 hex>` | a UUID |
| `Workflows` `create({ id })` of 101 characters | `(instance.invalid_id) Instance has invalid id` | |
| `Assets` content type of a `.txt` | `text/plain` | `text/plain; charset=utf-8` |
| `RateLimit` limit 2 in 60 s, 3 calls | `Ok`, `Ok`, `Ok` (not exact on the edge) | `Ok`, `Ok`, `RateLimited` |
| `Tcp.connect_with!` to port 443 of an HTTP host | `proxy request failed, cannot connect to the specified address. It looks like you might be trying to connect to a HTTP-based service` (then a dash and `consider using fetch instead`) | |
| `Tcp.start_tls!` on a socket with `tls: Off` | `TypeError`: ``The `secureTransport` socket option must be set to 'starttls' for startTls to be used.`` | |
| A Durable Object class of `new_classes` on the Free plan (deploy) | `In order to use Durable Objects with a free plan, you must create a namespace using a new_sqlite_classes migration. [code: 10097]` | |
| `limits.cpu_ms` on the Free plan (deploy) | `CPU limits are not supported for the Free plan. [code: 100328]` | |
| `waitUntil` past 30 s after the response | log `waitUntil() tasks did not complete within the allowed time after invocation end and have been cancelled.` | |
| The D1 constraint texts, the `Kv` texts, the RPC limit text, `TypeError: Invalid URL`, `TimeoutError` | the same as local | |

## Error texts of `WebCrypto` (PLAN.md 8c, local, 2026-10-16)

| Call | JS `name` | JS `message` |
| --- | --- | --- |
| `generate_key!(Pbkdf2)` | `NotSupportedError` | `Unrecognized key generation algorithm "PBKDF2" requested.` |
| `import_key!` of a private RSA JWK with the usage `verify` | `SyntaxError` | `Attempt to import private RSASSA-PKCS1-v1_5 key with invalid usage "verify".` |
| `sign!` with a ref that is not a `CryptoKey` (a pin that is not there) | `TypeError` | `Failed to execute 'sign' on 'SubtleCrypto': parameter 2 is not of type 'CryptoKey'.` |
| `decrypt!` in `call!` (the revert) | `PromiseInCall` (status 2) | `op 2 (call) gave a promise: the program needs await!` |
## Error texts of R2 and Cache (PLAN.md 8c, local, 2026-10-16)

The docs do not give the JS `name` and `message` of an R2 or Cache API error. These are the texts that `conformance/run.mjs` got (Miniflare 5.20261012.0-beta, workerd 2026-10-12). Each one is `R2Err(Thrown)` or `CacheErr(Thrown)`: the modules have no named tag for them (MODULES.md MC9). The edge run is 11c. A text with a number in brackets is a code of R2.

| Call | JS `name` | JS `message` | Tag |
| --- | --- | --- | --- |
| `put_with!` of a `Body.writer!` stream with no `length_bytes` | `TypeError` | `Provided readable stream must have a known length (request/response body or readable half of FixedLengthStream)` | `R2Err` |
| `put_with!` of a stream with `length_bytes` 5 and 11 bytes | `TypeError` | `Attempt to write too many bytes through a FixedLengthStream.` | `R2Err` |
| `put_with!` with a wrong `Sha256` | `Error` | `put: The SHA-256 checksum you specified did not match what we received.` (then the two hashes) `(10037)` | `R2Err` |
| `put_with!` with an `etag_matches` in quotes | `TypeError` | `Conditional ETag should not be wrapped in quotes ("abc").` | `R2Err` |
| `upload_part!` after `abort!`, and with an upload id that does not exist | `Error` | `uploadPart: The specified multipart upload does not exist. (10024)` | `R2Err` |
| `complete!` with a part whose etag R2 does not know | `Error` | `completeMultipartUpload: One or more of the specified parts could not be found. (10025)` | `R2Err` |
| `createMultipartUpload(key, uploadId)` (the revert of the `Upload` functions) | `TypeError` | `Failed to execute 'createMultipartUpload' on 'R2Bucket': parameter 2 is not of type 'MultipartOptions'.` | `R2Err` |
| `Cache.put!` of a 206 response | `TypeError` | `Cannot cache response to a range request (206 Partial Content).` | `CacheErr` |

A missing key is no error: `get` and `head` give `null`, `cache.match` gives `undefined`, `delete` gives `false`.

## Error texts of D1 (PLAN.md 8c, 8d, local, 2026-10-16)

The docs give no example of a D1 constraint error. These are the texts that `conformance/checks/d1.mjs` got (Miniflare 5.20261012.0-beta, workerd 2026-10-12): the same statement in the binding of Miniflare, and in the module through the bridge, gives the same text. Each error has the JS `name` `Error`. The edge run is 11c.

| Call | JS `message` | Tag |
| --- | --- | --- |
| `run!`: a primary key | `D1_ERROR: UNIQUE constraint failed: t.id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_PRIMARYKEY)` | `Constraint({ kind: PrimaryKey, message: "UNIQUE constraint failed: t.id" })` |
| `run!`: a `UNIQUE` column | `D1_ERROR: UNIQUE constraint failed: t.u: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_UNIQUE)` | `Unique` |
| `run!`: `NOT NULL` | `D1_ERROR: NOT NULL constraint failed: t.n: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_NOTNULL)` | `NotNull` |
| `run!`: `CHECK` | `D1_ERROR: CHECK constraint failed: c >= 0: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_CHECK)` | `Check` |
| `run!`: a foreign key | `D1_ERROR: FOREIGN KEY constraint failed: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_FOREIGNKEY)` | `ForeignKey` |
| `run!`: a `STRICT` column | `D1_ERROR: cannot store TEXT value in INTEGER column s.v: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_DATATYPE)` | `Datatype` |
| `run!`: a trigger `RAISE(ABORT, 'UNIQUE constraint failed: x')` | `D1_ERROR: UNIQUE constraint failed: x: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)` | `Trigger` |
| `batch!`: a trigger `RAISE(ABORT, 'label-conflict')` in the second statement | `D1_ERROR: label-conflict: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)` | `Trigger`, message `label-conflict`; the first insert is not written |
| `exec!`: a primary key | `D1_EXEC_ERROR: Error in line 1: INSERT INTO t (id, u, n, c) VALUES (1, 'q', 1, 1): UNIQUE constraint failed: t.id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_PRIMARYKEY)` | `PrimaryKey`, message from `Error in line 1: ` |
| `run!`: a syntax error | `D1_ERROR: near "SELEC": syntax error at offset 0: SQLITE_ERROR` | `D1Err` |
| A `BigInt` parameter (the revert of the parameter rule) | `D1_TYPE_ERROR: Type 'bigint' not supported for value '9007199254740993'` | `D1Err` |
| `all!`, `rows!`, `batch!` of rows above the limit (`pf.pack`, `pf.limit`, `pf.packEach`) | name `TooLarge`: `CBOR: output is larger than <n> bytes` (`<n>`: the end of the limit in the result block) | `TooLarge` |
| `with_session!(After(b))` with a bad bookmark | no throw locally (the workerd source has `D1_SESSION_ERROR`) | |

## Error texts of Queue and Kv (PLAN.md 8f, part 2, local, 2026-10-16)

The texts that `conformance/checks/queue.mjs` and `kv.mjs` got (Miniflare 5.20261012.0-beta, workerd 2026-10-12). Each error has the JS `name` `Error`. The edge run is 11c.

| Call | JS `message` | Tag |
| --- | --- | --- |
| `Queue.send_batch!` of 101 messages | `Unknown Internal Error (15000)` | `QueueErr` |
| `Kv.get_with!` with `cache_ttl_ms` 5,000 | `KV GET failed: 400 Invalid cache_ttl of 5. Cache TTL must be at least 30.` | `KvErr` |
| `Kv.put_with!` with `ttl_ms` 10,000 | `KV PUT failed: 400 Invalid expiration_ttl of 10. Expiration TTL must be at least 60.` | `KvErr` |

## Error texts of Durable Objects and RPC (PLAN.md 8f, part 1, local, 2026-10-16)

The texts that `research/objects-probe/probe.mjs` (`out.txt`) and `conformance/checks/objects.mjs` and `rpc.mjs` got (Miniflare 5.20261012.0-beta, workerd 2026-10-12). Object SQL gives the texts of D1 with no `D1_ERROR: ` at the start. Each SQL error has the JS `name` `Error` and the own properties `stack` and `message`. The edge run is 11c.

| Call | JS `name` and `message` | Tag |
| --- | --- | --- |
| `sql_run!`: a primary key | `Error`: `UNIQUE constraint failed: t.id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_PRIMARYKEY)` | `Constraint({ kind: PrimaryKey, message: "UNIQUE constraint failed: t.id" })` |
| `sql_run!`: a `UNIQUE` index, `NOT NULL`, `CHECK`, a foreign key, a `STRICT` column | As D1 (section above) with no `D1_ERROR: ` | `Unique`, `NotNull`, `Check`, `ForeignKey` (foreign keys are on), `Datatype` |
| `sql!`: a syntax error | `Error`: `near "SELEC": syntax error at offset 0: SQLITE_ERROR` | `SqlErr` |
| A `BigInt` parameter | `TypeError`: `Cannot convert a BigInt value to a number` | (the parameter rule of D1 sends text) |
| `sql!` of rows above the limit | `TooLarge`: `CBOR: output is larger than <n> bytes` | `TooLarge` |
| `set_alarm!` in a class with no `alarm!` (no `alarm` method) | `TypeError`: `Your Durable Object class must have an alarm() handler in order to call setAlarm()` | `StorageErr` |
| `jurisdiction(Eu)`, then `id!` | `Error`: `Jurisdiction restrictions are not implemented in workerd.` | `ObjectErr` |
| A KV-backed class (`useSQLite: false`): `ctx.storage.sql.databaseSize` | `Error`: `SQL is not enabled for this Durable Object class. To enable it, change \`new_classes\` to \`new_sqlite_classes\` within the 'migrations' field in your wrangler.jsonc or wrangler.toml file. If using workerd directly,set \`enableSql = true\` in your workerd config for the class. Note that this change cannot be made after the class is already deployed to production.` (no class name) | The shim throws `Durable Object class KvOnly: the platform needs a SQLite-backed class: ...` with this text after it |
| An `init!` that gives `Err` | The shim throws `<class>.init: failed: <error>`. The caller gets it as the error of its `fetch` (the next request makes a new object). | `ObjectErr` |
| An `init!` past the `Init` deadline | `<class>.init: cancelled: deadline` | `ObjectErr` |
| An RPC method that the callee does not have | `TypeError`: `The RPC receiver does not implement the method "nothere".` | `RpcErr` |
| An RPC callee that gives `Err(Nope(3))` | `Error`: `Nope(3)` | `RpcErr` |
| An RPC reply above 32 MiB (a text of 33,554,432 bytes) | Workers: `Serialized RPC arguments or return values are limited to 32MiB, but the size of this value was: 33554440 bytes.` (before `pf.pack` of the caller) | `RpcErr` |

Facts of local workerd for the same run: `rowsWritten` of a cursor of an insert of 2 rows is 2 before and after the iteration, and `rowsRead` is 0. An INTEGER of 2^53 + 1 reads back as 2^53 (rounded), and `CAST(x AS TEXT)` gives the exact value. `storage.kv.list()` gives an iterator of `[key, value]`. `kv.get` of a missing key gives `undefined`. The alarm retries come at about 0 s, 2.4 s and 6.7 s, with `alarmInfo` `{ retryCount, isRetry }`. `deleteAll` with the compatibility date 2025-06-01 keeps the alarm, and with 2026-10-01 it removes it. `getByName(name, { locationHint: "bogus" })` gives no error locally (`research/objects-probe/hint.txt`).

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

## Cost of the checks (12f)

Step 12f of `../PLAN.md`: what the sums and the global check cost in the full app (`app.roc`: a list of items to JSON, 50 call levels, 2 waits). 64 requests at once, 200 and 2,000 items, variant B (one instance), v7 allocator. Each mode runs with the checks of 12e on (`heapCheckEvery` 100, idle check on). Date 2026-10-16. Node 26.7, workerd 2026-10-12, nightly 10-12. The machine is a desktop with 24 cores and a background load of 0.8 to 2.7. No other job of mine ran during a measurement.

Modes:

| Mode | `resumeCheck` | Sum mode of the host | Sums |
|---|---|---|---|
| off | `"off"` | 0 (bench host only: the production host refuses it) | None |
| afterAlarm | `"afterAlarm"` | 1 | At each wait. At a resume only after an alarm. |
| always | `"always"` (default) | 2 | At each wait. At each resume after other code ran (here: at each resume). |

### CPU in Node (`sumcost.mjs`)

Waits that resolve at once, so the time is CPU. 3,000 requests after a warm-up. 11 runs of each cell, bench host and production host in turn in each run. The table has the median, the lowest and the highest run, in µs per request. "Against off" is the median against the median of `"off"` on the bench host.

| Items | Host | Mode | Median | Lowest to highest | Against off | Sum checks per wait | Wasm memory, MB | Wrong bodies |
|---|---|---|---|---|---|---|---|---|
| 200 | bench | off | 249.2 | 247 to 272 | 0 | 0 | 8.1 | 0 |
| 200 | bench | afterAlarm | 254.0 | 252 to 261 | +1.9 % | 0 | 8.1 | 0 |
| 200 | bench | always | 257.5 | 255 to 276 | +3.3 % | 1.0 | 8.1 | 0 |
| 200 | production | afterAlarm | 251.0 | 248 to 262 | +0.7 % | 0 | 7.8 | 0 |
| 200 | production | always | 253.9 | 251 to 269 | +1.9 % | 1.0 | 7.8 | 0 |
| 2,000 | bench | off | 2,304.1 | 2,263 to 2,345 | 0 | 0 | 52.8 | 0 |
| 2,000 | bench | afterAlarm | 2,354.0 | 2,337 to 2,442 | +2.2 % | 0 | 52.8 | 0 |
| 2,000 | bench | always | 2,418.1 | 2,383 to 2,522 | +4.9 % | 1.0 | 52.8 | 0 |
| 2,000 | production | afterAlarm | 2,337.1 | 2,307 to 2,665 | +1.4 % | 0 | 52.5 | 0 |
| 2,000 | production | always | 2,389.7 | 2,367 to 2,646 | +3.7 % | 1.0 | 52.5 | 0 |

Each cell had 30 global checks in 3,300 requests (the count of `heapChecks`), so the 12e checks were on. Memory is the same in all modes. The largest run of a cell has the same memory as the median.

Production against bench, same mode: -1.2 % and -1.4 % (200 items), -0.7 % and -1.2 % (2,000 items). The production host costs the same, and a little less. The bench host has about 0.3 MB more memory at 200 items (7.8 against 8.1 MB). The cause is not checked. (The production host has no `task_waits`: the script counts 2 waits for each request there.)

### Cost of the `live_peak` compare (`hostlib/alloc.zig`, `liveAdd`)

`liveAdd` makes one compare at each allocation: `if (LIVE_BYTES > LIVE_PEAK) LIVE_PEAK = LIVE_BYTES`. The test: a bench host with that line removed (`bench/out-nopeak/app.wasm`), against the normal bench host. Modes `"off"` and `"always"`. Two sets of 9 runs, each with the other order of the two files, so 18 runs for each cell. Median in µs per request.

| Items | Mode | Normal | No compare | No compare against normal |
|---|---|---|---|---|
| 200 | off | 249.3 | 255.3 | +2.4 % |
| 200 | always | 261.1 | 259.0 | -0.8 % |
| 2,000 | off | 2,269.9 | 2,291.8 | +1.0 % |
| 2,000 | always | 2,409.2 | 2,401.3 | -0.3 % |

The signs differ and the size is at most 1 % apart from one cell, which has the highest run of 296 µs. The cost of the compare is below what this bench can measure (about 1 %). The compare reads a global that is in the cache, and it writes only at a new peak. It stays.

### CPU in workerd (`bench.mjs`)

Local workerd, 5,000 requests after 1,000 of warm-up, 64 at once, depth 50, waits through the echo service (5 ms and 1 ms). Seven runs of each cell, a new workerd for each run, the modes in turn. "CPU" is the CPU time of the workerd process (`utime` plus `stime` from `/proc`) for each request. It has the echo service and the HTTP work too, so the part of wasm is the difference between the modes. The production host is not in this table: the configs embed `out/app.wasm` (the bench host), and the Node table shows that the two hosts cost the same.

| Items | Mode | CPU µs per request, median (lowest to highest) | Against off | Requests per second | p50 ms | p99 ms | Wasm memory, MB | Wrong bodies and errors |
|---|---|---|---|---|---|---|---|---|
| 200 | off | 526 (494 to 552) | 0 | 1,839 | 32.4 | 80.6 | 8.5 | 0 |
| 200 | afterAlarm | 524 (498 to 586) | -0.4 % | 1,860 | 32.8 | 77.4 | 8.6 | 0 |
| 200 | always | 522 (510 to 576) | -0.8 % | 1,869 | 32.6 | 80.8 | 8.6 | 0 |
| 2,000 | off | 3,032 (3,014 to 3,152) | 0 | 330 | 189.9 | 259.7 | 53.9 | 0 |
| 2,000 | afterAlarm | 3,124 (3,100 to 3,148) | +3.0 % | 321 | 196.3 | 258.3 | 54.6 | 0 |
| 2,000 | always | 3,224 (3,200 to 3,290) | +6.3 % | 311 | 203.3 | 262.4 | 54.3 | 0 |

At 200 items the checks are inside the noise (the spread is 10 %). At 2,000 items the cost is +92 µs and +192 µs for each request, a little more than in Node (+50 and +114 µs). The host counter `sumChecks` confirms the mode: 0 (off, afterAlarm) and 12,000 (always, 6,000 requests with 2 waits). 62 global checks in each run, 0 alarms, 0 replaces.

### Global check (`checkcost.mjs`, 5 runs)

| Items | Heap | Check | Request (CPU) | N from the rule | Cost with N = 100, share of the CPU | Limit |
|---|---|---|---|---|---|---|
| 200 | 5.8 MB | 0.024 ms | 263.2 µs | 100 | 0.073 % | 0.1 % |
| 2,000 | 47.9 MB | 0.037 ms | 2,376.2 µs | 20 | 0.022 % | 0.1 % |

PASS. The default `heapCheckEvery` of 100 holds.

### Reproduce

```sh
ZIG=<zig 0.17> bench/build.sh
# CPU in Node: bench host and production host, all modes (the production host skips "off")
RAW=.cache/results/12f-main.json node bench/sumcost.mjs bench/out/app.wasm,bench/out/app_prod.wasm 3000 11
# live_peak: build a bench host with the compare removed, then restore hostlib/alloc.zig
cp hostlib/alloc.zig .cache/alloc.zig.orig
sed -i '/if (LIVE_BYTES > LIVE_PEAK) LIVE_PEAK = LIVE_BYTES;/d' hostlib/alloc.zig
ZIG=<zig 0.17> bash -c '"$ZIG" build -Dbench=true && mkdir -p bench/out-nopeak && "$ROC" build --opt=speed --target=wasm32 --no-cache --output=bench/out-nopeak/app.wasm bench/app.roc'
cp .cache/alloc.zig.orig hostlib/alloc.zig
ZIG=<zig 0.17> bench/build.sh                                    # the normal host again
MODES=off,always node bench/sumcost.mjs bench/out/app.wasm,bench/out-nopeak/app.wasm 3000 9
MODES=off,always node bench/sumcost.mjs bench/out-nopeak/app.wasm,bench/out/app.wasm 3000 9
# CPU in workerd: one workerd for each run, the modes in turn
for m in off afterAlarm always; do
  WORKERD=<workerd> RESUME_CHECK=$m ITEMS=2000 CONCS=64 VARIANTS=b DEPTHS=50 node bench/bench.mjs 1 5000
done
node bench/checkcost.mjs bench/out/app.wasm 3000 5               # the global check (12d, 12e)
```

`sumcost.mjs` takes a list of files (comma). Env: `ITEMS`, `CONC`, `MODES`, `RAW` (the runs as JSON). `bench.mjs` takes the env `RESUME_CHECK` (a binding of `config-b.capnp`, read in `worker.js`), `ITEMS` and `CONCS`, and each row has `cpuUsPerReq`.

### Notes

| Point | Detail |
|---|---|
| Absolute times | The times are 10 to 15 % above the times of 12a (223.9 and 2,003.8 µs with no sums) and of 12d (226.9 and 2,080.7 µs). `checkcost.mjs` gave 263.2 and 2,376.2 µs in the same session, so the cause is not the new script. The cause is the machine (load 2.5, governor `powersave`), not the code: a build of commit `d8d9e96` and the current tree, run in turn, give the same times (2,000 items, no sums: 2,282 and 2,292 µs against 2,320 and 2,301 µs). The ratios between the modes are the result of this measurement. |
| Spread | Less than 3 % between the lowest and the highest run for most cells. The cells with one slow run (2,665 µs, 296 µs) show that a single run can be 10 % off, so each cell is the median of 9 to 18 runs. |
