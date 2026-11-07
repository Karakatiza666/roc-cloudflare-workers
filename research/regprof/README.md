# Where the CPU of a registry request goes

The Talon registry Worker (`talon/worker`, platform 0.0.7) runs locally in Miniflare and workerd. The requests are the scenarios of `talon/research/bench`. This directory profiles the workerd process with `perf` and the V8 jitdump, and puts each sample into one part.

Files in `talon/` outside `cloudflare-workers/` are only read.

## Files

| File | Use |
| --- | --- |
| `regserve.mjs` | A copy of `talon/worker/tests/serve.mjs`. Miniflare gets `inspectorPort` (env `INSPECT_PORT`, default 9230) |
| `serve.sh` | Starts `regserve.mjs` on 127.0.0.1:8787 with `MINIFLARE_WORKERD_V8_FLAGS=--perf-prof`. The cwd is `perf/`, so the jitdump of workerd goes there. `POST /__regserve/stop` closes the app, then exits (a trace of `CFW_TEST_TRACE` needs it: `research/alloc/scripts/regtrace.sh`) |
| `regprof.mjs` | Sends the requests of a scenario. `--perf`: `perf record --call-graph fp` on workerd during the measured requests, then `perf inject --jit`, then `perfstacks.mjs`. Also the CPU time of the workerd and node processes from `/proc`. Without `--perf`: the V8 profiler over the inspector (not used: the samples of workerd are not regular) |
| `perfstacks.mjs` | Puts each perf sample into a part, from its call stack (below) |
| `buckets.mjs` | Sums the parts into the rows of the tables below |
| `wasminfo.mjs` | Sections, body sizes and names of a wasm file. Also reads the symbol table of an object file (the platform `host.wasm`) |
| `state/`, `scenarios/` | The seed (`talon/research/bench/local.mjs --seed-only --dir state`) and the scenarios made from the local server (`gen-scenarios.mjs`) |
| `w2/`, `w2dbg/` | Copies of `talon/worker/app.wasm` and `.roc-cfw/`. `w2dbg/app.wasm` is a build with names (below) |

## Run

```
cd cloudflare-workers/research/regprof
cp ../../../worker/app.wasm w2/ && cp -r ../../../worker/.roc-cfw w2/
(cd ../../.. && node research/bench/local.mjs --seed-only --dir cloudflare-workers/research/regprof/state)
./serve.sh &                                  # W2_DIR=$PWD/w2dbg for the build with names
node regprof.mjs --perf --scenario small --warm 20 --repeat 200 --host <platform host.wasm> --json > perf/small.json
node regprof.mjs --perf --scenario closure --warm 10 --repeat 5 --host <platform host.wasm> --json > perf/closure.json
node regprof.mjs --perf --first --scenario small --host <platform host.wasm>   # a fresh server: the first request
node buckets.mjs perf/small.json perf/closure.json
```

`--host`: the `targets/wasm32/host.wasm` of the platform release (0.0.7: download the release `.tar.zst`). `app.wasm` has no name section. The roc linker puts the host functions first, in host order (3 of 185 are dropped), so `regprof.mjs` aligns them with the symbol table of `host.wasm` (the 31 exports are anchors, body sizes between them). The other functions (index 186 and up) are Roc code.

## How a sample gets its part

| Stack | Part |
|---|---|
| The JS frame nearest to the root is `entry.worker.js` or `miniflare:shared` | Miniflare entry worker (routing). Not on the edge |
| Same, `database.worker.js` or `cloudflare-internal:d1-api` | Miniflare D1 (SQLite in a Durable Object). On the edge D1 is a remote service |
| Same, `cache.worker.js` | Miniflare Cache API |
| A frame of `.roc-cfw/*.js`, `hooks.js` or wasm | The user Worker. The leaf gives the part: a wasm function (by name), a shim file (JS, V8 builtins and the interpreter count for the nearest shim frame), workerd API C++ (`workerd::api`, `jsg`), V8 GC, V8 runtime, the lazy compile of a wasm function |
| No JS frame | workerd outside JS: HTTP, RPC between the Miniflare workers, the event loop, the kernel, zlib (the gzip of the answer), SQLite, V8 GC and compile threads |

## Results (2026-11-07)

Machine shared with other agents. Steady state: after `--warm` rounds of the scenario. ms of CPU per request (perf samples at 10 kHz), and the share of the workerd CPU. The node process (the HTTP proxy of `regserve.mjs` and the Miniflare host) is apart: 1.3 ms (`small`) and 3.2 ms (`closure`) per request.

| Part | `small` (2 GETs: toolchains, a 404) | `closure` (59 `POST /v1/closure`) |
|---|---|---|
| Wall time, median | 3.2 ms | 8.7 ms |
| workerd CPU (`/proc`) | 2.0 ms | 6.4 ms |
| Miniflare and local D1 (not on the edge) | 0.39 ms (20 %) | 2.33 ms (36 %) |
| workerd outside JS (HTTP, RPC, event loop, kernel, gzip) | 0.81 ms (41 %) | 1.72 ms (27 %) |
| V8: GC, compile (tier-up), runtime | 0.23 ms (12 %) | 0.74 ms (12 %) |
| workerd API called by the shim (Request, Response, Headers, D1 and Cache bindings) | 0.20 ms (10 %) | 0.44 ms (7 %) |
| Shim JS (all files but the codec) | 0.12 ms (6 %) | 0.22 ms (3 %) |
| CBOR codec (shim `cbor.js`, `values.js`, host CBOR) | 0.07 ms (3 %) | 0.19 ms (3 %) |
| wasm: Roc code (app, builtins, refcount; JSON is in here) | 0.10 ms (5 %) | 0.64 ms (10 %) |
| wasm: allocator | 0.02 ms (1 %) | 0.08 ms (1 %) |
| wasm: global check (`check_heap`) and sums | 0.04 ms (2 %) | 0.04 ms (1 %) |
| wasm: host, other | 0.01 ms | 0.04 ms |

The user Worker alone (the rows from "V8" down, an upper bound: the V8 row also has GC and compile threads of the other workers): about 0.8 ms for `small` and 2.4 ms for `closure`. In it, for `closure`: Roc code 27 %, V8 31 %, workerd API 19 %, shim JS 9 %, CBOR 8 %, allocator 3 %, check and sums 1.5 %.

The build with names (`w2dbg`) splits the Roc code of `closure`: app procedures 0.46 ms, refcount (`roc_llvm_rc_*`) 0.05 ms, builtins (Str, List) 0.04 ms.

### Startup: the first request of a fresh server

| Request | Wall | workerd CPU | Of it |
|---|---|---|---|
| 1st (`GET /v1/toolchains`) | 107 to 119 ms | 77 to 80 ms | 52 ms lazy compile of wasm functions at their first call (Liftoff); 39 ms of it is function 186 (called by the 73-byte function 1860). 11 ms other V8 compile, 7 to 8 ms workerd I/O |
| 2nd (a first `closure`) | 69 ms | 30 to 32 ms | 15 ms lazy compile of wasm functions, 3 ms other compile, 3 ms GC, 5 ms Miniflare D1 |
| Steady `closure` | 8.7 ms | 6.4 ms | as the table above |

Before the first request, workerd used 5.2 s of CPU to start all the Miniflare workers, with `--perf-prof` on (not on the edge). The first requests of an isolate pay the compile of each wasm function that they call first: about 70 ms over the first two requests here, above the 10 ms CPU limit of the free plan. The largest function (index 186, 1.25 MB of code) takes 39 ms of it.

### Names in the wasm

| Way | Cost | What it gives |
|---|---|---|
| Align with the platform `host.wasm` (`--host`) | None (this script) | Names of the host functions (allocator, CBOR, sums, check). Roc code stays one part |
| `roc build --opt=speed --debug --target=wasm32 --output=<dir>/app.wasm main.roc` in `talon/worker` | 3.7 min, nothing written in `talon/worker` | A `name` section: host and builtin names, `roc_llvm_rc_*`, and the app procedures as `roc__p<hash>.fast` (no source names). Note: a different code layout (1,829 functions, function 186 is 0.73 MB), so compare parts, not functions |
