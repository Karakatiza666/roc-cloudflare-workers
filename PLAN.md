# Plan: fix the gaps found in the audit (2026-10-13)

The audit compared this platform with wasm-bindgen and workers-rs (Rust), workers-zig and Zig std, Go, TinyGo and workers-go, Pyodide and Python Workers, Emscripten, Almide, soli_lang and plumekit. This plan fixes the 5 problems it found (1 to 5).

A second audit (2026-10-13) compared the code with the design in `../DESIGN.md` §10.1 and §10.2. It found 3 bugs, 6 gaps between the design and the code, and 4 design risks. Problems 6 to 11 fix them. The numbers 1 to 5 stay as they are, because other files refer to them.

| # | Problem | Effect |
|---|---|---|
| 1 | In builds from nightlies before 2026-10-11, data is below the stack. A stack overflow writes over data and globals. | Silent heap corruption. The instance stays in use. |
| 2 | A JS import can throw into a waiting task | The task's owner id and its saved stack copy are lost. Its heap leaks. |
| 3 | A wait that never settles (the client disconnects) | The task's saved stack copy and heap leak forever |
| 4 | Pool rules: "up to 16 per instance" and an open count | More memory, no gain |
| 5 | The CPU limit stops the instance in a task | `task_abort` does not run. The instance state is stale. |
| 6 | Host bugs: the log buffer has the owner tag of a task (B1), `num` goes to JS as an `f64` (B2), JS does not read `c` and `num` (B3) | B1: heap corruption with no trap after a `dbg` and a `crash`, and a leak for each `dbg`. B2: values above 2^53 change. B3: no effect can send binary data. |
| 7 | The platform ABI has bench exports (R1), the build settings are given by hand (R3), the glue can drift (R4) | `set_copy(0)` breaks requests that run at the same time. A plain `roc build` gives the wrong stack size. An ABI change is not seen. |
| 8 | The platform API is not the designed API: `Str => Str` (G1), raw kind numbers (G2), status 0 on all errors (G3), only a fetch handler (G4) | The registry cannot take binary uploads, has no types, no test seam, no error causes and no cron |
| 9 | The JS shim is bench code, and `io` has no request context (G5) | No entry module for users. No `ctx.waitUntil`, `request.signal` or headers in an effect. |
| 10 | All bodies go through wasm memory (R2) | A large R2 object uses wasm memory that never gets smaller |
| 11 | No release (G6) | Nobody can use the platform by URL |

## Order of work

| Order | Items | Depends on |
|---|---|---|
| 1 | 1a, 1a-ci, 1b to 1d (done) | none |
| 2 | 6a to 6c | none. 6a corrupts the heap, so it comes first. |
| 3 | 2a to 2d | none |
| 4 | 3.0 (workerd facts), then 3a to 3d | the task table (2c) |
| 5 | 4 | cancel (3c) |
| 6 | 5a to 5c. 5d (edge) waits for a deployed worker in 11. | none |
| 7 | 7a to 7c | none. Before 8, because 8 changes the exports. |
| 8 | 8a to 8e | the split ABI (7a), the header settings (7b) |
| 9 | 9a to 9c | the task table (2c), the API (8) |
| 10 | 10a to 10c | the API (8), the shim (9) |
| 11 | 11a to 11c, then 5d on the edge | 7 to 10 |
| 12 | Update DESIGN.md §10.1, §10.2 and `bench/README.md` | all |

Each new test must fail when its change is reverted.

## 1. Stack overflow corrupts data

### Experiment: can we rely on the linker flag?

Yes. No roc change is needed: nightlies from 2026-10-11 already link stack-first.

Setup:
- `bench/app_deep.roc` recurses with no heap allocation. Each level returns a 16-field record, which uses 176 B of shadow stack.
- 10-09 relinked: the app objects (kept with `roc build --keep-temp`) relinked with `zig wasm-ld --stack-first`.
- The probe is a Node script that uses `bench/core.js`, variant B.

| Build | Layout | Depth 1000 to 4000 | Depth 6000 (about 1.05 MB of shadow stack) | Deeper, or small frames |
|---|---|---|---|---|
| nightly 10-09 (`258ab27`) | data at 1,033, `__stack_pointer` starts at 1,313,168 | ok | The response is "ok". The canary is broken, and the stack wrote into the data and globals below it. Nothing detects it. | V8 `RangeError: Maximum call stack size exceeded` |
| nightly 10-09, relinked with `--stack-first` | stack 0 to 1 MB, then data | ok | `RuntimeError: memory access out of bounds`. `task_abort` returns -1, so the instance is retired. The next request is correct. | same RangeError |
| nightly 10-11 (`7d256b9`) and 10-12 (`2664a27`), no change | stack 0 to 1 MB, data at 1,048,585 | ok | same as the relinked build (checked on 10-12) | not run |

Facts:
- roc passes no layout flag to wasm-ld (`../roc/src/cli/linker.zig:690-750`, roc `9ec02d8c48`). The layout is the LLD default.
- roc `a76bc229ba` (2026-10-07) moved to the LLVM 22 bundles from roc-bootstrap `zig-0.17.0` (`build.zig.zon`). LLD 22 defaults to stack-first (`zig wasm-ld --help`: "--stack-first: Place stack at start of linear memory (default)").
- Nightly 10-09 (`258ab27`) is older than that commit. 10-11 and 10-12 contain it. 10-10 was not checked.
- The relinked 10-09 app passes `bench/node-test.mjs` unchanged.
- `bench/README.md:175` says our layout is stack-first. That is wrong for the 10-09 build.

Conclusion:
- With stack-first, an overflow is a sure out-of-bounds trap, and nothing lies below the stack to corrupt.
- The canary stays for one reason: in a recursion that allocates, it gives a clean trap, so the instance stays.
- With data-first, no check can make the layout safe. A check can only find the damage after it happened.
- The layout comes from a linker default, not from a roc decision, so it can change again without notice. The host must check it at run time (1b).

### Upstream: who decides the layout?

Do not hard-code it in roc. Stack-first is already the result, and hard-coding the default would add nothing. If an explicit control is wanted, the platform must own it, because the host code (the canary, `task_abort`) depends on the layout. roc already reads wasm link settings from the platform header (`src/compile/targets_config.zig:64-75`: `import_memory`, `minimum_memory`, `maximum_memory`, `initial_stack_size`, `global_base`).

| Option | Who decides | Upstream fit |
|---|---|---|
| Hard-code `--stack-first` | roc | Poor: no choice, and it repeats the LLD default |
| CLI flag `--wasm-stack-first` | the app user | Poor: the app user does not know the host's needs |
| Field `stack_first : Bool` in the wasm32 target record of the platform header, passed to wasm-ld as `--stack-first` or `--no-stack-first` | the platform author | Good: same pattern as `global_base` and `initial_stack_size` |
| No change. Add a roc test that a wasm32 build is stack-first. | nobody (the default) | Good, and the smallest |

Plan: no PR is needed for this platform. Open an issue that proposes the last row (a test), and offers the header field if they want explicit control.

### Build check: `bench/check-layout.mjs`

A script reads the linked wasm and gives the layout. It does not run the module.

| Reads | How |
|---|---|
| Start value of `__stack_pointer` | The global with that name in the name section (debug builds). Else the first defined mutable i32 global: wasm-ld puts `__stack_pointer` first and `--strip-all` removes the names. |
| Data segments | The `i32.const` offset and length of each active segment |
| Verdict | STACK-FIRST when the stack pointer starts at or below the lowest data segment. Else DATA-FIRST. UNKNOWN when it cannot tell (no such global, a non-constant offset, no data, not wasm). |

Usage: `node bench/check-layout.mjs <app.wasm>...`. Exit 0: all stack-first. 1: one is data-first. 2: one is unknown.

Checked (2026-10-13):

| File | Verdict | Exit |
|---|---|---|
| `bench/out/app.wasm`, `bench/out/app_pad.wasm` (nightly 10-09) | DATA-FIRST (stack pointer 1,313,904 and 3,411,056; data from 1,033) | 1 |
| `app_deep.roc`, nightly 10-09, stripped and `--debug` | DATA-FIRST (found by position, and by name) | 1 |
| `app_deep.roc`, nightly 10-12, stripped and `--debug` | STACK-FIRST (stack pointer 1,048,576; data from 1,048,585) | 0 |
| 10-09 objects relinked with `--stack-first` | STACK-FIRST | 0 |
| `platform/targets/wasm32/host.wasm` (an object, not linked) | UNKNOWN | 2 |
| `README.md` | UNKNOWN (not a wasm module) | 2 |

### What happens when the stack is not first

The platform does not stop. It falls back to variant A: a new instance for each request, and never more than one request in an instance. An overflow can then corrupt only the instance of that one request, and the instance is dropped when the request ends. The cost is the variant A cost: about 100 to 150 µs more CPU per request for the 49 KB bench module, and 1.3 MB of memory per request in flight (`bench/README.md`). The request that overflowed can still return a wrong body without an error. Only a stack-first build removes that risk.

| Layout | Instances | Requests per instance |
|---|---|---|
| STACK-FIRST | pool of 3 (problem 4) | all requests, at the same time |
| DATA-FIRST or UNKNOWN | one per request | 1 |

### Steps

| Step | Change | Test |
|---|---|---|
| 1a | `bench/check-layout.mjs` (done, see above). `bench/build.sh` runs it on each output and prints a warning when a result is not STACK-FIRST. It does not fail the build. | The table above |
| 1a-ci | CI job on each new nightly: build the bench app and `app_deep.roc`, run the script, run `bench/overflow-test.mjs`. On STACK-FIRST, write the nightly to `compat/last-stack-first-nightly` (the newest nightly that passed). On DATA-FIRST or UNKNOWN, the job fails and notifies us: we open the upstream issue. A release of the platform and of talon pins the nightly in that file, so a regression in a nightly never blocks a release. | Run the job on 10-09 (must fail) and 10-12 (must pass and record) |
| 1b | Run time check, the safety net for a module built in some other way: `init` finds the layout. The stack is first when the stack address is below the address of a host global (exact for any stack size; "floor == 0" was wrong for a data-first build with a stack smaller than `STACK_SIZE`). Add the export `stack_first()`, and list it in `platform/main.roc`. JS uses the fallback above when it returns 0. Cost: one comparison per instance in `init`, and one choice per module load in JS. No cost per request. Only the fallback costs, and only when it is used. | 10-09 build: each request gets a new instance. 10-12 build: one shared instance. |
| 1c | A canary trap is clean only when the stack is first. Otherwise it is unclean. | `bench/overflow-test.mjs` with `app_deep.roc` at depths 1000 to 20000, on the 10-12 build: the first trap retires the instance, and no request returns a body while the canary is broken. On the 10-09 build with the fallback off, the test must fail. |
| 1d | First pinned nightly: 2026-10-12 (10-11 also passes; there is no 10-10 nightly). Move `bench/build.sh` to nightly 10-12 and rerun `bench/node-test.mjs`. Fix `bench/README.md:175`. Open the upstream issue above. | |

### Status of step 1 (2026-10-13)

| Step | State | Where |
|---|---|---|
| 1a | Done | `bench/build.sh` (uses `bench/get-roc.sh`, builds `app_deep.wasm` too, warns) |
| 1a-ci | Done. Not run on GitHub yet: the repo has no GitHub remote. | `bench/ci-layout.sh`, `.github/workflows/nightly-layout.yml`. Local: 10-09 exit 1, file not changed. 10-12 exit 0, file written. |
| 1b | Done | `hostlib/canary.zig` (`STACK_FIRST`, `stack_first()`), `bench/core.js` (`makeRunner`: fallback, `opts.noFallback`) |
| 1c | Done | `hostlib/canary.zig` (`check`). `bench/core.js` also gives new requests a new instance after `task_abort` returns -1 (before, it only counted it). |
| 1d | Done. Upstream issue: roc-lang/roc#12270 | `compat/last-stack-first-nightly`, `bench/README.md` |

Tests:

| Build | `overflow-test.mjs` | `node-test.mjs` |
|---|---|---|
| 10-12 | PASS. 4500: out of bounds, retired. 4500 alloc: canary trap, clean, instance kept. | PASS |
| 10-09 | PASS with the fallback (one instance per request) | PASS (variant b falls back) |
| 10-09, `--no-fallback` | FAIL: bodies at 4500 and 5000 with a broken canary | |

`app_deep.roc` now takes `<depth> alloc`, so the overflow test covers the canary trap. The test computes each expected body in JS. Depths 4500 and 5000 were added: on 10-09 the silent overwrite happens only while the stack is past the canary and still above the data.

Revert checks (each test must fail):

| Revert | Build | Result |
|---|---|---|
| 1c: the canary trap is always clean | 10-09, `--no-fallback` | FAIL: the unclean trap did not retire the instance |
| 1b: `STACK_FIRST = true` | 10-09 | FAIL: the next request traps |
| 1b: `STACK_FIRST = false` | 10-12, `--expect-shared` | FAIL: the runner fell back |
| No retire in `core.js` | 10-12 | FAIL: the unclean trap did not retire the instance |

The canary check at each wait from the first version of this plan is dropped. The CI check with the pinned nightly, the run time check and the fallback replace it.

## 2. A JS import throws into a waiting task

A throw at the resume point skips `waitEnd`. Then the task's owner id is lost (`OWNER` is 0 while it waits), and so is its `Wait` record with the saved copy.

| Source of the throw | Now |
|---|---|
| io rejects | Caught (`bench/core.js:16-20`) |
| `js_alloc` runs out of memory while the task waits (`hostlib/alloc.zig:279`) | Not caught. `allocOrTrap` also sets the global `TRAP_CLEAN` from a host call while no task runs. |
| A bug in the wrapper | Not caught |
| V8 `RangeError` (engine stack, see the table in problem 1) | Unclean, so the instance is retired. That is correct. |

| Step | Change | Test |
|---|---|---|
| 2a | `js_alloc` returns 0 on out of memory and does not trap. JS gives the task an error status. | Test export `fail_next_alloc` |
| 2b | `makeWait` (`bench/core.js:9-27`) puts one try/catch around all the code after it reads the arguments. It always returns a status and never rejects (as Pyodide `suspenders.c` and the wasm-bindgen `catch` imports do). | io that throws synchronously; io that rejects |
| 2c | Task table in the host. JS gives each task an id: `handle(p, l, id)`. The host keeps each `Wait` in a table by id. `task_abort(id)` frees the saved copy and calls `freeOwner(id)`, also when `waitEnd` did not run. Problems 3 and 4 use this table. | Force a throw into a waiting task: live bytes return to 0 |
| 2d | `TRAP_CLEAN` is set only while a task runs (`OWNER != 0`), and is cleared when `handle` starts | A trap in a host call from JS is unclean |

## 3. A wait that never settles

When workerd drops a request (for example, the client disconnects), its I/O promises may never settle. The suspended task then keeps its saved copy and its tagged heap blocks forever. plumekit only retires the whole instance after a timeout. Owner tags let us free only that task.

### 3.0 Facts to get first (local workerd test, client disconnects during a wait)

| Question | Why it matters |
|---|---|
| Does the I/O promise ever settle? | If it does, there is no leak |
| Does `request.signal` fire (compatibility flag `enable_request_signal`)? | A direct cancel signal |
| Do the timers of the dropped request still fire? | If not, a deadline must be checked from other requests |
| Is a suspended continuation freed by GC when nothing refers to it? | Step 3c depends on it |

### Steps

| Step | Change | Test |
|---|---|---|
| 3a | JS task table: id to `{instance, waitingSince, cancelled}` | |
| 3b | Each new request first sweeps the table (it runs in a live request context). A task that waits longer than the deadline is cancelled. The default deadline is 120 s and is configurable. Also cancel on `request.signal`, if 3.0 shows that it fires. | |
| 3c | `task_cancel(id)` frees the saved copy and calls `freeOwner(id)`. If the I/O settles later, the import wrapper returns a promise that never settles, so the wasm never resumes onto freed memory. | Node: io that never resolves for some ids. Expect live bytes 0, the other requests correct, and flat memory over 10,000 cancels. |
| 3d | A draining instance with only cancelled tasks is dropped | Covered by problem 4 test |

## 4. Pool size

Any cap is the same code: the cap is one constant. Settle on 3.

| Question | Answer |
|---|---|
| Does one isolate serve many requests at once? | Yes, on one thread, switching at each await. One instance with the stack copy serves all of them. Keeping that instance across requests, with no reset, gives variant B its 1.3 to 1.8x throughput over A. |
| Do more active instances help? | No. There is no CPU gain on one thread. Each instance adds fixed memory (1 MB stack, the data, its own heap high-water mark), and free blocks in one instance cannot serve another. |
| Why 3? | 1 active plus up to 2 draining. 3 × 32 MB (the retire threshold) plus about 32 MB for JS fits the 128 MB isolate limit. |

Rules:
- All new requests go to the active instance. Remove the "up to 16 per instance" rule.
- When the active instance retires, start a new one. This costs 28 to 36 µs for a 49 KB module, and about 0.5 ms for 2 MB. Do not keep a warm spare unless the module grows past 2 MB.
- If a third retire happens while 2 instances drain, cancel the tasks of the oldest draining instance (3c) and drop it.

Test: force retires under load (out-of-bounds traps). Expect at most 3 instances, 0 bad bodies, and a clear error for each cancelled task.

## 5. The CPU limit stops the instance in a task

When workerd stops a request at its CPU limit, no catch runs. `task_abort` does not run, so `TASK_TOP`, the stack pointer and `OWNER` stay stale.

### What `__instance_signal` and `__instance_terminated` are

workerd registers each wasm instance that exports one or both of these globals. A shim on `WebAssembly.instantiate` and `new WebAssembly.Instance` does this. Each global holds the address of a `u32` in linear memory. Sources: workerd `1fa5622`, `src/workerd/io/wasm-instantiate-shim.js:38-58`, `src/workerd/io/tracked-wasm-instance.h:24-35`.

| Export | The runtime writes | When | Source | Our use |
|---|---|---|---|---|
| `__instance_signal` | 24 (`SIGXCPU`), then 0 to clear it | The CPU time of the request is nearly used up | `tracked-wasm-instance.c++:54-73` | The host checks it on each allocation (next to the canary check) and in `waitBegin`. When it is set, the task gets a clean trap: free its spans, answer 503, keep the instance. |
| `__instance_terminated` | 1 | The isolate was stopped for going over the CPU limit | `tracked-wasm-instance.c++:75-85` | `handle` checks it first. When it is set, JS retires the instance. |

How others use them:
- workers-rs only shows the signal to the program as `is_near_cpu_limit()` (`worker/src/signal.rs`, workers-rs `b171cb4bdd6f`). It starts the value at 0xFFFF, so a 0 proves that the runtime registered the module.
- wasm-bindgen sets the terminated flag on each abort, and the next export call then makes a new instance (`guide/src/reference/handling-aborts.md:20-63`, wasm-bindgen `f57e205b2bc0`).

Limits:
- The code that writes the flags is not in open-source workerd, which has no CPU limit. A local test can only write the address itself.
- Not verified: does the isolate keep running after the terminated write? The wasm-bindgen reinit design assumes it does. Check this on the real edge.

### Steps

| Step | Change | Test |
|---|---|---|
| 5a | Export both globals from the Zig host, with the 0xFFFF start value. Add them to the `exports` list in `platform/main.roc`. Check that the build exports them as globals. | Read the export section |
| 5b | Check the signal on allocation and in `waitBegin`. Clean trap with the cause "cpu". | Node: write 24 during a request. Expect a 503, live bytes 0, other requests correct. |
| 5c | Check the terminated flag at `handle`, and retire when it is set | Node: write 1 between requests, with stale `TASK_TOP` |
| 5d | Edge test: a handler that loops past the CPU limit. Does the signal arrive? Does the isolate survive? | Deployed worker |

## 6. Host bugs (second audit)

| Bug | Where | Now |
|---|---|---|
| B1 | `hostlib/roc.zig:13-19`, `hostlib/wordbuf.zig:13-15`, `hostlib/alloc.zig:177` | `logPushCopy` and the growth of the `LOG` buffer allocate with `OWNER` = the task that runs. No JS code calls `log_ptr`, `log_len` or `log_clear`. After a clean trap, `freeOwner` frees the buffer and its entries while `LOG.ptr` still points to them. The next `dbg` writes into a freed span that can be in use by another task. Each `dbg` also leaks, because nothing drains the log. |
| B2 | `host/host.zig:115,125` | The import `js_wait` takes `num` as an `f64` (`@floatFromInt`). Values above 2^53 change with no error. |
| B3 | `bench/core.js:456-460` | `makeWait` reads `a` and `b`, but not `c` (bytes) or `num`. |

| Step | Change | Test |
|---|---|---|
| 6a | Host-owned allocations use owner 0: put `OWNER = 0` around `logPushCopy` and `WordBuf.push` (as `js_alloc` does at `hostlib/alloc.zig:279-286`). JS drains the log after each `handle` and after each `task_abort`, and calls `log_clear`. | `bench/app.roc` request option `dbg`: a `dbg`, then a `crash`. Run 200 such requests mixed with good requests on one instance. Expect live bytes 0 at the end and 0 bad bodies. Revert the owner change: the test must fail. |
| 6b | The import takes `num` as `i64`. JS gets a `BigInt` (JS BigInt integration). | io that echoes `num` as text, with 2^53 + 1 and 2^64 - 1. Revert: the echo is wrong. |
| 6c | `makeWait` reads `cp, cl` as bytes and `num` before its first `await`, and gives them to `io`. | io that echoes `c`, with bytes that are not UTF-8 (0x00 to 0xFF). Revert: the bytes are not passed. |

## 7. ABI and build settings

| Risk | Where | Now |
|---|---|---|
| R1 | `platform/main.roc:12` | The exports list has bench and test functions: `set_copy`, `copy_bench`, `alloc_bench`, `heap_fill`, `walk_bench`, `stats_reset`. `set_copy(0)` on a shared instance made 24 of 64 requests trap (`bench/README.md:182`). |
| R3 | `hostlib/canary.zig:1`, `bench/build.sh:94-95` | `STACK_SIZE` must equal `--wasm-stack-size` by hand, and each user must pass `--wasm-memory=0`. |
| R4 | `host/roc_platform_abi.zig` | The generated glue (975 lines) is committed. A change in a new nightly is not seen. |

| Step | Change | Test |
|---|---|---|
| 7a | Two export lists: production (`init`, `handle`, `task_abort`, `js_alloc`, `res_free`, `stack_first`, the log exports, the CPU globals of 5a) and bench (all others). One way: a second platform file `bench/platform/main.roc` that adds the bench exports, and a build option that leaves the bench functions out of the production host. | Read the export section of a production build: no bench export. The bench tests still pass on the bench build. |
| 7b | Put the stack size and the memory settings in the `targets.wasm32` record of the platform header (`initial_stack_size`, `minimum_memory`, `maximum_memory`; read in `roc:src/compile/targets_config.zig:67-74`). `hostlib/canary.zig` gets `STACK_SIZE` from the same build value. Remove the flags from `bench/build.sh`. | Build with a plain `roc build --target=wasm32`. `check-layout.mjs` gives STACK-FIRST with a 1 MB stack. Remove the header field: the stack size changes. |
| 7c | `bench/ci-layout.sh` makes the glue again and fails on a diff with the committed file. | Change one line in the committed glue: CI fails. |

## 8. Platform API

| Gap | Design says (`../DESIGN.md` §10.1, §10.2) | Code has |
|---|---|---|
| G1 | A generic fetch handler | `requires { handle! : Str => Str }` (`platform/main.roc:2`). No method, headers or status. The body must be UTF-8. |
| G2 | A `Worker` capability record (`fetch!`, `d1!`, `r2!`, `cache!`) and a scripted record for unit tests | The app imports `pf.Wait` and uses raw kind numbers (`bench/app.roc:10,14`) |
| G3 | Effect errors are results | Status 0 on any error. JS drops the message (`bench/core.js:466`). |
| G4 | The registry runs a compat bot and ingest | Only the fetch handler |

| Step | Change | Test |
|---|---|---|
| 8a | `Request` (method, url, headers, body bytes) and `Response` (status, headers, body bytes) types. `requires { fetch! : Request, Worker => Response }`. JS encodes them in one js_alloc block, and the host decodes them. | Node: binary body (0x00 to 0xFF) round trip, 100 headers, status 404. Revert to `Str`: the test fails. |
| 8b | Typed effects as Roc functions over `Wait.wait!`: `fetch!`, `d1_query!`, `d1_batch!`, `r2_get!`, `r2_put!`, `kv_get!`, `kv_put!`, `cache_match!`, `cache_put!`. They are fields of the `Worker` record. `Wait` is not in `exposes`. | Each effect against a Node fake of the binding |
| 8c | A scripted `Worker` record for tests with no host (as roc-shpadoinkle `package/Await.roc:20-33`) | `roc test` of a handler with a scripted record |
| 8d | Effects return `Try(ok, WorkerErr)`. JS writes the error kind and the message in the result block. | io that throws: Roc gets the message. A 404 and a network error give different tags. |
| 8e | More entry points: `scheduled!` (cron) and `queue!` (a batch of messages). A missing one is not exported. | Node: call each entry point. workerd: a cron trigger runs `scheduled!`. |

## 9. JS shim

| Gap | Now |
|---|---|
| G5 | The shim is `bench/core.js`, mixed with test code (`expected`, `check`). `bench/worker.js:621` makes `io` from the `env` of the first request. `io` has no `ctx.waitUntil`, no `request.signal` and no request headers. |

| Step | Change | Test |
|---|---|---|
| 9a | Move the runtime to `js/` (one entry module, for example `js/index.js` that exports `makeHandler(module)`). It returns `{ fetch, scheduled, queue }` for the Worker. Test helpers stay in `bench/`. | `bench/worker.js` and the Node tests use `js/` and still pass |
| 9b | The `io` call gets the task id. The task table (2c) keeps the request context of each task: `env`, `ctx`, the `Request`. | Two requests at the same time with different headers. Each effect sees the headers of its own request. Revert to one shared context: the test fails. |
| 9c | `ctx.waitUntil` as an effect | A `waitUntil` promise runs after the response |

## 10. Body handles

| Risk | Now |
|---|---|
| R2 | All bodies go through wasm memory, and wasm memory never gets smaller. A 10 MB R2 object uses 10 MB of the 128 MB isolate limit for the life of the instance (and counts toward the 32 MB retire rule of problem 4). |

| Step | Change | Test |
|---|---|---|
| 10a | JS keeps large bodies (`ReadableStream`, `Response`) in a table, and Roc gets an opaque `Body` id. `Response` can give a `Body` back to JS with no copy into wasm. | Node: send an R2 object of 50 MB through `r2_get!` to the response. wasm memory grows by less than 1 MB. |
| 10b | `body_read!(Body, max)` copies the bytes into wasm only when Roc needs them. Ingest needs only `main.roc` from the archive. | Read the first 1 KB of a 50 MB body |
| 10c | The task table frees the body ids of a task at its end, its trap and its cancel (3c) | After 10,000 requests with traps and cancels, the body table is empty |

## 11. Release

| Gap | Now |
|---|---|
| G6 | `platform/targets/` is in `.gitignore`. There is no release workflow, so a user cannot use the platform by URL. |

| Step | Change | Test |
|---|---|---|
| 11a | A release workflow: build the production host (7a) with the pinned nightly (`compat/last-stack-first-nightly`), bundle the platform with `roc bundle`, and attach the bundle and the `js/` package to a GitHub Release | Run on a test tag. A new app builds with the release URL. |
| 11b | Publish `js/` (npm, or a file in the release that the app copies) | A new Worker project uses it with wrangler |
| 11c | An example Worker app with a wrangler config, deployed by CI. 5d (CPU limit on the edge) runs on it. | The deployed example answers. 5d gives its results. |

## Done when

- All tests above pass, and each fails when its change is reverted.
- `bench/node-test.mjs` and the leak test still give 0 bad bodies and live bytes 0.
- DESIGN.md §10.1, §10.2 and `bench/README.md` show the new rules: stack-first, the task table, cancel, the pool of 3, the CPU signals, the platform API (8), the shim (9), body handles (10) and the release (11).
