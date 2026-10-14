# Plan: fix the gaps found in the audit (2026-10-13)

The audit compared this platform with wasm-bindgen and workers-rs (Rust), workers-zig and Zig std, Go, TinyGo and workers-go, Pyodide and Python Workers, Emscripten, Almide, soli_lang and plumekit. This plan fixes the 5 problems it found (1 to 5).

A second audit (2026-10-13) compared the code with the design in `../DESIGN.md` §6.1 and `../DESIGN-REGISTRY.md` §8. It found 4 bugs, 6 gaps between the design and the code, and 4 design risks. Problems 6 to 11 fix them. The numbers 1 to 5 stay as they are, because other files refer to them.

Problem 12 (2026-10-14) is the goal of problem 4: one wasm instance per isolate. Each task checks at resume that its memory is unchanged, so a host bug does not make the whole instance untrusted. In this plan, a wild write is a write to a wrong address in linear memory, from a host bug or a compiler bug.

| # | Problem | Effect |
|---|---|---|
| 1 | In builds from nightlies before 2026-10-11, data is below the stack. A stack overflow writes over data and globals. | Silent heap corruption. The instance stays in use. |
| 2 | A JS import can throw into a waiting task | The task's owner id and its saved stack copy are lost. Its heap leaks. |
| 3 | A wait that never settles (the client disconnects) | The task's saved stack copy and heap leak forever |
| 4 | Memory: pool rules ("up to 16 per instance", a pool of 3, a retire at 32 MB) and no limit on `memory.grow` | One large request can stop the whole isolate. More instances give more memory and no gain. |
| 5 | The CPU limit stops the instance in a task | `task_abort` does not run. The instance state is stale. |
| 6 | Host bugs: the log buffer has the owner tag of a task (B1), `num` goes to JS as an `f64` (B2), JS does not read `c` and `num` (B3), a failed allocation returns 0 to Roc (B4), large free spans are never joined or split (B5) | B1: heap corruption with no trap after a `dbg` and a `crash`, and a leak for each `dbg`. B2: values above 2^53 change. B3: no effect can send binary data. B4: a write through 0 goes into the bottom of the stack with no trap. B5: a string built in a loop takes memory that grows with the square of its length, and stops the isolate. |
| 7 | The platform ABI has bench exports (R1), the build settings are given by hand (R3), the glue can drift (R4) | `set_copy(0)` breaks requests that run at the same time. A plain `roc build` gives the wrong stack size. An ABI change is not seen. |
| 8 | The platform API is not the designed API: `Str => Str` (G1), raw kind numbers (G2), status 0 on all errors (G3), only a fetch handler (G4) | The registry cannot take binary uploads, has no types, no test seam, no error causes and no cron |
| 9 | The JS shim is bench code, and `io` has no request context (G5) | No entry module for users. No `ctx.waitUntil`, `request.signal` or headers in an effect. |
| 10 | All bodies go through wasm memory (R2) | A large R2 object uses wasm memory that never gets smaller |
| 11 | No release (G6) | Nobody can use the platform by URL |
| 12 | After an unclean trap, any part of the instance's memory can be damaged. Today the only answer is a new instance and a drain of the old one. | Two instances in one isolate (memory), and tasks that resume onto damaged memory return wrong bodies with status 200 |

## Order of work

| Order | Items | Depends on |
|---|---|---|
| 1 | 1a, 1a-ci, 1b to 1d (done) | none |
| 2 | 6e, then 6a to 6d | none. 6e replaces `hostlib/alloc.zig`, so 6a, 6d and 2a change the new file. 6e also fixes B5, which can stop the isolate with ordinary Roc code. 6a corrupts the heap, so it comes next. |
| 3 | 2a to 2d | none |
| 4 | 3a to 3c (3.0 is done) | the task table (2c) |
| 5 | 4-pre, 4a, then 12-pre, 12a, 12a-stack, 12b, 12d, 12c, 12e, 12f, then 4b to 4j (V1 to V4 are done) | the v7 allocator (6e), the task table (2c), cancel (3c), the clean OOM (6d). 12c needs one instance (4a) and the global check (12d). |
| 6 | 5a to 5c. 5d (edge) waits for a deployed worker in 11. | none |
| 7 | 7a to 7c | none. Before 8, because 8 changes the exports. |
| 8 | 8a to 8e | the split ABI (7a), the header settings (7b) |
| 9 | 9a to 9c | the task table (2c), the API (8) |
| 10 | 10a to 10c | the API (8), the shim (9) |
| 11 | 11a to 11c, then 5d on the edge | 7 to 10 |
| 12 | Update DESIGN.md §6.1, DESIGN-REGISTRY.md §8 and `bench/README.md` | all |
| 13 | 12g: measure with talon | talon runs on the platform |

Each new test must fail when its change is reverted. Exceptions: moves, releases and edge runs (9a, 11a to 11c, 5d) and comparisons (the replay row of 6e). Their test is that the old tests still pass, or the run gives its numbers.

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
- With stack-first, an overflow is a sure out-of-bounds trap, and nothing is below the stack to corrupt.
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

The platform does not stop. It falls back to variant A: a new instance for each request, and never more than one request in an instance. An overflow can then corrupt only the instance of that one request. The instance is dropped when the request ends. The request that overflowed can still return a wrong body without an error. Only a stack-first build removes that risk.

Cost of variant A with the v7 allocator (6e), full app (`research/alloc/README.md`, "Benchmarks"):

| | 200 items | 2,000 items |
|---|---|---|
| More CPU per request than variant B | 130 to 160 µs | 400 to 500 µs |
| Memory per request in flight | 2.4 MB (each instance has the 0.9 MB unit tables) | 3.6 MB |
| Memory, 64 requests at once | 152 MB | 232 MB |

So the fallback must limit the instances to the budget (M9).

| Layout | Instances | Requests per instance |
|---|---|---|
| STACK-FIRST | one instance (problem 4, M1) | all requests, at the same time |
| DATA-FIRST or UNKNOWN | one per request | 1 |

### Steps

| Step | Change | Test |
|---|---|---|
| 1a | `bench/check-layout.mjs` (done, see above). `bench/build.sh` runs it on each output and prints a warning when a result is not STACK-FIRST. It does not fail the build. | The table above |
| 1a-ci | CI job on each new nightly: build the bench app and `app_deep.roc`, run the script, run `bench/overflow-test.mjs`. On STACK-FIRST, write the nightly to `compat/last-stack-first-nightly` (the newest nightly that passed). On DATA-FIRST or UNKNOWN, the job fails and notifies us: we open the upstream issue. A release of the platform and of talon pins the nightly in that file, so a regression in a nightly never blocks a release. | Run the job on 10-09 (must fail) and 10-12 (must pass and record) |
| 1b | Run time check, the safety net for a module built in some other way. `init` finds the layout: the stack is first when the stack address is below the address of a host global. This is exact for any stack size. ("floor == 0" was wrong for a data-first build with a stack smaller than `STACK_SIZE`.) Add the export `stack_first()`, and list it in `platform/main.roc`. JS uses the fallback above when it returns 0. Cost: one comparison per instance in `init`, and one choice per module load in JS. There is no cost per request. Only the fallback costs, and only when it is used. | 10-09 build: each request gets a new instance. 10-12 build: one shared instance. |
| 1c | A canary trap is clean only when the stack is first. Otherwise it is unclean. | `bench/overflow-test.mjs` with `app_deep.roc` at depths 1000 to 20000, on the 10-12 build: no request returns a body while the canary is broken. The first trap is unclean (`task_abort` returns -1). After 4-pre (problem 4), an overflow with no alloc on a stack-first build is clean, and the instance is kept. On the 10-09 build with the fallback off, the test must fail. |
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
| 10-12 | PASS. 4500: out of bounds, retired. 4500 alloc: canary trap, clean, instance kept. After 4-pre the expectation changes: 4500 with no alloc is clean, the instance is kept, live bytes are 0, and the next request is correct. | PASS |
| 10-09 | PASS with the fallback (one instance per request) | PASS (variant b falls back) |
| 10-09, `--no-fallback` | FAIL: bodies at 4500 and 5000 with a broken canary | |

`app_deep.roc` now takes `<depth> alloc`, so the overflow test covers the canary trap. The test computes each expected body in JS. Depths 4500 and 5000 were added: on 10-09 the silent overwrite happens only while the stack is past the canary and still above the data.

Revert checks (each test must fail):

| Revert | Build | Result |
|---|---|---|
| 1c: the canary trap is always clean | 10-09, `--no-fallback` | FAIL: the unclean trap did not retire the instance |
| 1b: `STACK_FIRST = true` | 10-09 | FAIL: the next request traps |
| 1b: `STACK_FIRST = false` | 10-12, `--expect-shared` | FAIL: the runner fell back |
| No retire in `core.js` | 10-12 | FAIL: the unclean trap did not retire the instance. After 4-pre, an overflow is clean, so this check uses the forced out-of-bounds trap at normal stack depth (V2 in problem 4). |

The canary check at each wait from the first version of this plan is dropped. The CI check with the pinned nightly, the run time check and the fallback replace it.

Change after 12c: an unclean trap no longer retires the instance. It gives an alarm and the global check (problem 12). So the tests and revert checks above that look for "retired" or "a new instance" must look for the alarm instead: `task_abort` returns -1 and the alarm counter (M11) goes up. 12c makes this change in `overflow-test.mjs`.

## 2. A JS import throws into a waiting task

A throw at the resume point skips `waitEnd`. Then the task's owner id is lost (`OWNER` is 0 while it waits), and so is its `Wait` record with the saved copy.

| Source of the throw | Now |
|---|---|
| io rejects | Caught (`bench/core.js:16-20`) |
| `js_alloc` runs out of memory while the task waits (`hostlib/alloc.zig:279`) | Not caught. `allocOrTrap` also sets the global `TRAP_CLEAN` from a host call while no task runs. |
| A bug in the wrapper | Not caught |
| V8 `RangeError` (engine stack, see the table in problem 1) | Clean when the stack pointer shows an overflow (4-pre, V1). Else unclean: an alarm (12c). |

| Step | Change | Test |
|---|---|---|
| 2a | `js_alloc` returns 0 on out of memory and does not trap. JS gives the task an error status. | Test export `fail_next_alloc` (6d) before a `js_alloc`: the task gets an error status, and the other tasks are correct. Revert (trap): the waiting task is lost. |
| 2b | `makeWait` (`bench/core.js:9-27`) puts one try/catch around all the code after it reads the arguments. It always returns a status and never rejects (as Pyodide `suspenders.c` and the wasm-bindgen `catch` imports do). | io that throws synchronously; io that rejects. Both tasks get an error status. Revert (no try/catch): the sync throw skips `waitEnd`, and live bytes stay. |
| 2c | Task table in the host. JS gives each task an id: `handle(p, l, id)`. The host keeps each `Wait` in a table by id. `task_abort(id)` frees the saved copy and calls `freeOwner(id)`, also when `waitEnd` did not run. Problems 3 and 4 use this table. | Force a throw into a waiting task: live bytes return to 0. Revert (no table): live bytes stay. |
| 2d | `TRAP_CLEAN` is set only while a task runs (`OWNER != 0`), and is cleared when `handle` starts | A trap in a host call from JS is unclean. Revert: it is clean. |

## 3. A wait that never settles

When workerd drops a request (for example, the client disconnects), its I/O promises may never settle. The suspended task then keeps its saved copy and its tagged heap blocks forever. plumekit only retires the whole instance after a timeout. Owner tags let us free only that task.

### 3.0 Facts (measured 2026-10-14, local workerd, `research/workerd/`, results in `research/README.md`)

| Question | Why it matters | Answer |
|---|---|---|
| Does the I/O promise ever settle? | If it does, there is no leak | No. After a client reset (TCP RST), the I/O promises and timers of the request never settle. |
| Does `request.signal` fire (compatibility flag `enable_request_signal`)? | A direct cancel signal | Yes, only with the flag |
| Do the timers of the dropped request still fire? | If not, a deadline must be checked from other requests | No. So 3b checks the deadlines from other requests. |
| Is a suspended continuation freed by GC when nothing refers to it? | Step 3c depends on it | No. A suspended JSPI stack is never freed. Each one keeps about 6 KB of RSS and 1 MB of address space, and it keeps its instance from collection. So 3c must resume the stack once, to end it. |
| Does workerd have `FinalizationRegistry`? How long until a dropped instance of 30 MB is collected, under load and when idle? | M10 in problem 4 | Yes. Collected after 5.5 s with 64 requests at once, 20.1 s under memory pressure, and not in 60 s when idle. An instance with a task whose client reset is never collected (fixed by 3c). |
| How large is the JS heap of the shim under load (64 requests at once)? | The default of `jsReserveBytes` in problem 4 | 46 MB in use, 76 MB committed. Default: 48 MB. |
| Cost of a call to JS at each grow | M4 | `js_grow` call 6.2 ns, `memory.grow` 281 ns |

### Steps

| Step | Change | Test |
|---|---|---|
| 3a | JS task table: id to `{instance, waitingSince, cancelled, cancel}`. `cancel` resolves the cancel promise of 3c. | Used by the tests of 3b and 3c |
| 3b | Each new request first checks the table (it runs in a live request context). A task that waits longer than the deadline is cancelled (3c). The default deadline is 120 s and is configurable. Also cancel on `request.signal`. 3.0: it fires only with the compatibility flag `enable_request_signal`, so the shim documents the flag and 11c sets it. | Node: deadline 100 ms, io that never resolves for one request. The next request cancels it: it gets a 503, and live bytes return to 0. Abort the signal of a waiting request: it is cancelled at once. Revert (no check of the table): live bytes stay. |
| 3c | Cancel (`task_cancel(id)`): the host frees the saved copy and calls `freeOwner(id)`. Then the import wrapper must end the suspended stack, because a suspended JSPI stack is never freed and keeps its instance (3.0). The wrapper waits on `Promise.race([io, cancelPromise])`. On cancel, it returns the status "cancelled". The host checks this status first, before it reads or writes memory or a global, and runs `unreachable`. The trap ends the stack. JS knows that the task was cancelled, so this trap is not an alarm. A replace (M1) cancels all tasks of the old instance in the same way, so the old instance can be collected. | Node: io that never resolves for some ids. Expect live bytes 0, the other requests correct, and flat memory (RSS too) over 10,000 cancels. Replace an instance with 10 waiting tasks (`--expose-gc`): the `FinalizationRegistry` callback reports the old instance collected. Revert (a promise that never settles, as before): RSS grows by about 6 KB per cancel, and the old instance is not collected. |
| 3d | Removed (2026-10-14): no instance drains (problem 12) | |


## 4. Memory management

Decided on 2026-10-13. This replaces the old pool rules ("up to 16 per instance", a pool of 3, and a retire at 32 MB). Changed on 2026-10-14: one instance per isolate (problem 12), so there is no draining instance.

### Facts

| Fact | Source |
|---|---|
| Cloudflare limits the isolate to 128 MB. The JS heap and the linear memory of all wasm instances count. When the isolate goes over, Cloudflare stops it, and all requests in flight fail. | Cloudflare Workers limits. The exact behavior on the edge is checked in 11c. |
| Our modules declare no memory maximum (min 21 pages, max none in `bench/out/app_deep.wasm`). So `memory.grow` does not fail before the isolate limit. | roc adds `--max-memory` only when the header sets `maximum_memory` (`roc:src/cli/linker.zig:732-734`) |
| Almost all heap growth goes through one function: `bumpSpan` (`hostlib/alloc.zig:88-110`), `poolGrow` in v7 (6e). Only the roc boxy runtime takes pages itself, for its own tables, mostly at start (`roc:src/boxy_runtime/main.zig:143`). v7 marks those pages as foreign. | |
| A dropped instance is collected after 5.5 s under load, 20.1 s under pressure, and not in 60 s when idle (3.0) | So a drop cannot free memory for a grow that waits |
| Wasm memory never gets smaller. A dropped instance gives its memory back only when V8 collects it, and workerd cannot force a GC. | `memory.discard` (memory control proposal) is not in V8 |
| Live heap blocks cannot move: Roc values, the shadow stack, the saved stack copies and JS hold raw addresses, and there are no type maps or stack maps. | |
| `roc_alloc` and `roc_realloc` give 0 back to Roc when memory cannot grow (`hostlib/alloc.zig:219-231`). Address 0 is the bottom of the stack. | Fixed in 6d |

### Decisions

| # | Decision |
|---|---|
| M1 | One instance per isolate takes all requests. No instance drains. After an unclean trap, the instance stays when the checks of problem 12 pass. When they fail, the instance is replaced: all its tasks are cancelled (3c, each gets a 503), it is dropped, and a new instance starts. There is no replace for size. The new instance (about 2.4 MB at start) must fit in the budget next to the old one until the old one is collected (M10). If it does not fit, new requests get a 503 (pressure step 2) until the callback reports the old instance collected. |
| M2 | No fixed cap per instance by default. An instance grows as far as the isolate budget allows. |
| M3 | The budget is `isolateBytes` (128 MB) minus `jsReserveBytes`. JS counts `memory.buffer.byteLength` of each live instance, and of each dropped instance until it is collected (M10). |
| M4 | Each grow asks JS first. `poolGrow` calls the synchronous import `js_grow(pages)`, and grows only on yes. It grows by `max(needed, growStepBytes)`. The cost is small: a call costs 6.2 ns and a grow 281 ns (3.0), and a grow happens only above the high-water mark. |
| M5 | A developer cap is optional: the shim option `maxInstanceBytes`, checked by `js_grow`. The platform header sets no `maximum_memory`, because the app developer cannot change the platform header. |
| M6 | A grow that cannot be served gives a clean OOM trap to the task that asked (6d). That request gets a 503, its pages are freed (owner tags), and the instance stays in use. Memory never stops the whole isolate on purpose. |
| M7 | Under pressure, the steps below run in order, from the least severe to the most severe. |
| M8 | Removed (2026-10-14): it chose between an active and a draining instance. There is no draining instance. |
| M9 | Fallback (variant A, one instance per request, problem 1): each instance is a live request. An instance that needs memory waits up to `graceMs` for other requests to end, then gets a clean OOM. A new instance starts only when its initial memory fits the budget. Else the request waits in the queue. With v7, an instance starts at about 2.4 MB (the unit tables are 0.9 MB), so about 33 instances fit in the default budget of 80 MB. A smaller unit table for the fallback build (a lower `MAX_UNITS`) is an option. |
| M10 | A dropped instance counts in the budget until a `FinalizationRegistry` callback reports it collected (workerd has it, 3.0). There is no `collectWaitMs`. An instance with a suspended task is never collected, so a drop first cancels all its tasks (3c). |
| M11 | One log line, with the sizes or the cause, for each: denied grow, shed request, alarm (12c), failed global check (12d, 12e), replace (M1), cancel (3b, 3c), caught double free (`double_frees`), missed free (`dealloc_miss`). Each kind also has a counter export (H3). So the developer can see why the app is slow or fails. |

### Cap of 2 instances (removed 2026-10-14)

The cap of 2 bounded the instances while an old one drained. With one instance per isolate (problem 12), no instance drains. The old open question ("kill an instance at once on an unclean trap, or let its tasks finish") is answered by 12c: tasks whose sums match finish, and tasks whose sums differ get a 503.

V1 to V4 were measured (2026-10-14, `research/traps/`):

| # | Question | Result | Effect |
|---|---|---|---|
| V1 | Value of `__stack_pointer` after an overflow trap | Warm code: an out-of-bounds trap with the stack pointer wrapped (4,294,967,248). Cold (Liftoff) code: a V8 `RangeError`, and the stack pointer can be anywhere. A recursion that allocates: the canary `unreachable` (stack pointer 12,176). | 4-pre also counts a `RangeError` as clean. Safe: the allocator is in a sound state at each call where V8 can throw it. Needs 2c (the js_wait window). |
| V2 | Can a trap that is not an overflow look like one? | Traps at normal depth have the stack pointer between 855,872 and 1,047,872 | The rule holds |
| V3 | Does the rule depend on the layout? | On a data-first build, an overflow writes over data before it traps (problem 1) | The rule is only for stack-first builds |
| V4 | How often does a retire happen while an instance drains? | About 1 - e^(-rate x rps x drain time): 79 to 83 % at a trap rate of 1 %, 5 to 11 % at 0.1 % | With drains, the cap of 2 would act often. Problem 12 removes the drain. |

### Steps under memory pressure

A grow is under pressure when `js_grow` says no. Changed on 2026-10-14: with one instance, nothing can be pushed out, and a dropped instance frees its memory only seconds later (3.0). So the wait, gate and push-out steps are removed.

| Step | What | Applies when |
|---|---|---|
| 1. Reclaim | In the instance: give the page reserve back to the pool (done in v7, 6e), then try again | Always first |
| 2. Shed (refuse new requests) | New requests get a 503 while the instance is under pressure (`js_grow` said no in the last `graceMs`). Requests in flight continue. | After step 1 failed |
| 3. Fail the requester | Clean OOM trap for the task that asked (M6). Its pages go back, so the other tasks can continue. | Step 1 did not free enough |

### Heap optimization on memory pressure

Free space can only be reused in the same instance. It cannot go to another instance or back to the isolate.

To implement:

| # | Option | What it is | Why it is safe |
|---|---|---|---|
| H2 | Idle reset | When no task runs or waits on the instance and `LIVE_BYTES` is 0, the heap starts again: each region becomes empty, and the free lists are cleared. Foreign units (roc runtime) and host blocks stay. | O(number of regions). `LIVE_BYTES` can only be too high (a leak), never too low, so a wrong count stops the reset and never resets over live data. `log_clear` frees the empty `LOG` buffer, so 0 is reachable. Needs `track_live` on in production (it is the default). |
| H3 | Fragmentation counters | Exports for the heap bytes, the peak of `LIVE_BYTES`, the number of reclaim walks and the bytes they gained | Counters only. They give the numbers that the options below need. |

Need measurement (do not implement until the numbers show a gain):

| # | Option | What it is | What to measure |
|---|---|---|---|
| H7 | Replace for fragmentation | Replace the instance (M1) when the heap bytes divided by the peak of `LIVE_BYTES` (H3) go above a limit. Only when no task runs or waits (at an idle check, 12e), so no task is cancelled. | The ratio in long mixed runs and in talon (12g) |
| H8 | Size classes | v7 has 13 classes (16 to 2,048 B). The old 16 classes gave no change. | The waste in each class for real talon handlers (12g) |

Done or not needed:

| # | Option | State |
|---|---|---|
| H1 | Reclaim walk for small blocks | Not needed with v7 (6e): an empty small page goes back at once |
| H4 | Split large free blocks | Done in 6e |
| H5 | Join at each free | Done in 6e (v7 joins free runs at each free, with boundary tags in the unit tables) |
| H6 | Lower the top at each free | Not needed: v7 has no bump top. Free units join the free run at the top. |
| H9 | Grow step | Measured: 64 KB, the `growStepBytes` default (`research/heap-options/h9.jsonl`) |

`memory.discard` would let an instance give pages back. V8 does not have it. Check it again when V8 ships it.

### Developer options (shim, `makeHandler(module, opts)`)

| Option | Default | Use |
|---|---|---|
| `isolateBytes` | 128 MB | The Cloudflare limit |
| `jsReserveBytes` | 48 MB (3.0: the JS heap peaks at 46 MB in use) | The part of the budget for JS |
| `maxInstanceBytes` | none | Optional hard cap per instance (M5) |
| `growStepBytes` | 64 KB (H9) | M4 |
| `graceMs` | 1000 | Pressure step 2, and M9 |
| `queueLimit` | 100 | The queue of the fallback (M9) |
| `resumeCheck` | `"always"` | 12b. `"afterAlarm"`: check at resume only after an alarm (sum mode 1). It costs less, but misses a wild write with no trap. |
| `heapCheckEvery` | 1,000 at first. 12e sets it from the check time of 12d. | 12e. Run the shared-memory check after this many requests. 0: off. |
| `heapCheckWhenIdle` | `true` | 12e. Run the shared-memory check when the instance becomes idle |

### Steps

| Step | Change | Test |
|---|---|---|
| 4-pre | `task_abort` counts a trap as clean when the stack pointer shows an overflow (V1) and the layout is stack-first | `overflow-test.mjs`: at depth 4500 with no alloc, the instance is kept, live bytes are 0, and the next request is correct. Revert: the trap is unclean (the instance is replaced; after 12c, an alarm). V2 case: still unclean. |
| 4a | One instance (M1). Remove the "up to 16", the pool of 3, the 32 MB retire and the drain. A replace cancels all tasks of the old instance (3c). Until 12c, each unclean trap replaces the instance. | 1,000 requests with 1 % unclean traps: never more than 1 instance with tasks, 0 bad bodies. Revert (old pool): more than 1. |
| 4b | `js_grow` before each grow, the budget in JS, the grow step (M3, M4) | Node, `isolateBytes` 16 MB, `jsReserveBytes` 0: a request that allocates 20 MB gets a 503. Other requests are correct, live bytes return to 0, the instance stays. Revert (grow with no ask): memory goes over 16 MB. |
| 4c | `maxInstanceBytes` (M5) | Cap 8 MB: the same request fails at 8 MB. No cap: it passes with `isolateBytes` 64 MB and `jsReserveBytes` 0. Revert (no cap check): it passes with the cap. |
| 4d | The steps under pressure (M7): reclaim, shed, fail the requester | `isolateBytes` 16 MB, `jsReserveBytes` 0, 64 requests of 1 MB each: the requests that do not fit get a 503, new requests get a 503 for `graceMs`, the others are correct, live bytes return to 0. Revert the shed: new requests trap with OOM. |
| 4e | Count dropped instances until collected (M10) | workerd: drop an instance of 30 MB (a replace), then grow. The budget shows the 30 MB until the callback. Revert (count only the live instance): the budget drops at once, and the grow goes over `isolateBytes`. |
| 4f | Budget for the fallback (M9) | 10-09 build (data-first): 64 requests at once with `isolateBytes` 32 MB and `jsReserveBytes` 0. Requests wait and then pass. None goes over the budget. Revert (no budget for the fallback): memory goes over 32 MB. |
| 4g | Log lines and counters (M11) | Each case in 3b, 3c, 4b to 4f and 12c to 12e writes its line, and its counter goes up. Revert (remove one line): its test fails. |
| 4h | H3 counters | Values match a manual walk. Revert (a counter that is not updated): no match. |
| 4i | Done by 6e (v7: join, split, empty pages back at once) | |
| 4j | H2 idle reset | 1,000 requests with mixed sizes, then idle: heap bytes return to the base, foreign units and host blocks stay, and `check_heap` (12d) passes after the reset. A test that keeps one live block (a host block): no reset, no damage. Revert: heap bytes stay high. |


## 5. The CPU limit stops the instance in a task

When workerd stops a request at its CPU limit, no catch runs. `task_abort` does not run, so `TASK_TOP`, the stack pointer and `OWNER` stay stale.

### What `__instance_signal` and `__instance_terminated` are

workerd registers each wasm instance that exports one or both of these globals. A shim on `WebAssembly.instantiate` and `new WebAssembly.Instance` does this. Each global holds the address of a `u32` in linear memory. Sources: workerd `1fa5622`, `src/workerd/io/wasm-instantiate-shim.js:38-58`, `src/workerd/io/tracked-wasm-instance.h:24-35`.

| Export | The runtime writes | When | Source | Our use |
|---|---|---|---|---|
| `__instance_signal` | 24 (`SIGXCPU`), then 0 to clear it | The CPU time of the request is nearly used up | `tracked-wasm-instance.c++:54-73` | The host checks it on each allocation (next to the canary check) and in `waitBegin`. When it is set, the task gets a clean trap: free its pages, answer 503, keep the instance. |
| `__instance_terminated` | 1 | The isolate was stopped for going over the CPU limit | `tracked-wasm-instance.c++:75-85` | `handle` checks it first. When it is set, JS replaces the instance (M1). |

How others use them:
- workers-rs only shows the signal to the program as `is_near_cpu_limit()` (`worker/src/signal.rs`, workers-rs `b171cb4bdd6f`). It starts the value at 0xFFFF, so a 0 shows that the runtime registered the module.
- wasm-bindgen sets the terminated flag on each abort, and the next export call then makes a new instance (`guide/src/reference/handling-aborts.md:20-63`, wasm-bindgen `f57e205b2bc0`).

Limits:
- The code that writes the flags is not in open-source workerd, which has no CPU limit. A local test can only write the address itself.
- Not verified: does the isolate keep running after the terminated write? The wasm-bindgen reinit design assumes it does. Check this on the real edge.

### Steps

| Step | Change | Test |
|---|---|---|
| 5a | Export both globals from the Zig host, with the 0xFFFF start value. Add them to the `exports` list in `platform/main.roc`. Check that the build exports them as globals. | Read the export section. Revert (no export): the globals are missing. |
| 5b | Check the signal on allocation and in `waitBegin`. Clean trap with the cause "cpu". | Node: write 24 during a request. Expect a 503, live bytes 0, other requests correct. Revert (no check): the request runs to its end. |
| 5c | Check the terminated flag at `handle`, and replace the instance (M1) when it is set | Node: write 1 between requests, with stale `TASK_TOP`. Expect a new instance and a correct next request. Revert (no check): the next request runs on the stale state and traps. |
| 5d | Edge test: a handler that loops past the CPU limit. Does the signal arrive? Does the isolate survive? | Deployed worker |

## 6. Host bugs (second audit)

| Bug | Where | Now |
|---|---|---|
| B1 | `hostlib/roc.zig:13-19`, `hostlib/wordbuf.zig:13-15`, `hostlib/alloc.zig:177` | `logPushCopy` and the growth of the `LOG` buffer allocate with `OWNER` = the task that runs. No JS code calls `log_ptr`, `log_len` or `log_clear`. After a clean trap, `freeOwner` frees the buffer and its entries while `LOG.ptr` still points to them. The next `dbg` writes into a freed span that can be in use by another task. Each `dbg` also leaks, because nothing drains the log. |
| B2 | `host/host.zig:115,125` | The import `js_wait` takes `num` as an `f64` (`@floatFromInt`). Values above 2^53 change with no error. |
| B3 | `bench/core.js:456-460` | `makeWait` reads `a` and `b`, but not `c` (bytes) or `num`. |
| B4 | `hostlib/alloc.zig:219-231` | `roc_alloc` and `roc_realloc` return 0 to Roc when memory cannot grow. Address 0 is the bottom of the stack. Today `memory.grow` does not fail before the isolate is stopped. With `js_grow` (4b) it can fail. |
| B5 | `hostlib/alloc.zig:126-145`, `189-201` | Spans above 4 KB go on one free list with first fit, and are never split or joined. A string built in a loop (`$s = "${$s},${$i.to_str()}"`) asks at each step for a span a little larger than all freed ones, so each step takes new memory from the top. The free spans are next to each other, but nothing joins them. |

The line numbers in `hostlib/alloc.zig` in this plan are for the old file. 6e replaces the file, so the steps after 6e use the names of the functions.

B5, measured (2026-10-14, nightly 10-12, Node):

| Loop steps | Final string | Wasm memory now | With join and split (arena prototype) |
|---|---|---|---|
| 5,000 | 24 KB | 79 MB | 2.8 MB |
| 10,000 | 59 KB | 202 MB, more than the isolate limit | 2.8 MB |
| 40,000 | 240 KB | 4 GB, then the grow fails and B4 follows | 6.3 MB |

The same loop in the allocator harness of the heap measurements: 596 MB now, 0.4 MB with a join before each grow (H1) and a split of large spans (H4L). So join and split fix it, with or without an arena per task.

| Step | Change | Test |
|---|---|---|
| 6a | Host-owned allocations use owner 0: put `OWNER = 0` around `logPushCopy` and `WordBuf.push` (as `js_alloc` does). JS reads the log after each `handle` and after each `task_abort`, and then calls `log_clear`. | `bench/app.roc` request option `dbg`: a `dbg`, then a `crash`. Run 200 such requests mixed with good requests on one instance. Expect live bytes 0 at the end and 0 bad bodies. Revert the owner change: the test must fail. |
| 6b | The import takes `num` as `i64`. JS gets a `BigInt` (JS BigInt integration). | io that echoes `num` as text, with 2^53 + 1 and 2^64 - 1. Revert: the echo is wrong. |
| 6c | `makeWait` reads `cp, cl` as bytes and `num` before its first `await`, and gives them to `io`. | io that echoes `c`, with bytes that are not UTF-8 (0x00 to 0xFF). Revert: the bytes are not passed. |
| 6d | `roc_alloc` and `roc_realloc` trap clean on 0 (`trapClean`, as `allocOrTrap`) | Test export `fail_next_alloc` (added here, and 2a uses it too): the task gets a clean trap, `task_abort` frees its pages, the next request is correct. Revert: no clean trap. |
| 6e | Replace `hostlib/alloc.zig` with the v7 allocator (`research/alloc/versions/v7.zig`), without its research switches. See "6e: the v7 allocator" below. It fixes B5 (free runs join and split) and gives the per-task page lists that the sums of problem 12 need. | See the test table below |

### 6e: the v7 allocator

Chosen on 2026-10-14 from 8 versions (`research/alloc/README.md`). The first plan for 6e (the TLSF large island on the old allocator) is dropped: v5 (TLSF large pages) was slower than v6 and v7 on all traces, and used more memory.

Design:

| Part | v7 |
|---|---|
| Unit | 4 KB, up to 128 MB (u16 unit indexes). Tables per unit, outside the units (about 26 B per unit). |
| Small blocks (up to 2,048 B, 13 classes) | One class and one task per 4 KB page. No block header: the page tables give the class and the task. Slot index by a multiply (`(off * ceil(2^32/size)) >> 32`). Per task and class, a list of pages with room. Small pages take the lowest free unit. |
| Large blocks (above 2,048 B) | A run of whole units. Free runs: lists by length (exact below 8, then 8 lists per power of 2), boundary tags, a join with both neighbors at each free, a bounded walk of 8. Best fit at the top end of a run. |
| Realloc | Grows in place into the free run after the block. A moved block goes to the low end of a free run of 2x its size, so the next growth can be in place. Copies only up to the requested end. |
| Empty small page | Goes back at once, to a reserve of at most 256 pages that only small pages use. When memory cannot grow, the reserve goes back to the pool, then the large block tries again. |
| Double free | A freed small block holds a mark (random per instance, set by JS with `set_free_mark`) in word 0. On a match, the free checks the page's free list: on it, the free is ignored and counted; not on it, it is a live block and is freed. |
| JS blocks (`js_alloc`) | Own pages, with an owner word for `adopt` |
| Task end | Frees all pages and runs of the task in O(its pages) (`freeOwner`) |
| Sum of a task (problem 12) | The task record, its small pages up to the bump offset, its large blocks up to the requested end. Fletcher with SIMD (128-bit lanes). |

Measured (replay of recorded allocator calls of the real app, and synthetic traces; `research/alloc/README.md`, "Benchmarks"):

| | old (v0) | v7 |
|---|---|---|
| Real app, 64 tasks, 2,000 items, fresh process: memory MB | 164.4 | 52.9 (live peak 49.2) |
| Replay, 200 items: memory MB | 13.1 | 5.6 |
| Synthetic, buffers that grow to 1 MB: memory MB (live peak 64.4) | 212.2 | 70.8 |
| String loop, 80,000 steps: memory MB | out of memory | 5.3 |
| Replay, 2,000 items: ms per 384 requests, without sums / with a sum at each wait | 57 / 105 (sum by a heap walk) | 75 / 89 |
| Replay, 200 items: same | 29 / 106 | 54 / 65 |
| KB summed per wait, 2,000 items | 1,357 | 752 |
| Wild writes, sum mode 1 or 2: wrong bodies | 0 | 0 |

The small path is slower than the old allocator (one global free list per class) when no sums run. With sums, v7 is faster: the old allocator has no per-task page lists, so its sum must walk the heap.

Known cost: about 0.2 MB more bytes copied per request than v6 (the reserve takes units from the 2x runs of moved blocks). CPU is equal to v6. Tried and dropped: see `research/alloc/README.md`, "Settings tried".

Port:
- Keep the defaults: empty pages back at once, reserve of 256 pages with the drain at out of memory, moved block to a 2x run, grow at the top first.
- Remove the switches `set_keep_empty`, `set_page_cache`, `set_cache_max`, `set_cache_drain`, `set_place`, `set_grow_at_top`, and the counters that only the research uses.
- `poolGrow` is the only place that grows memory. Until 4b, it calls `memory.grow`. 4b makes it call `js_grow` first.
- `TRACK_LIVE` and `LIVE_BYTES` stay (H2, the tests).
- Add back the owner check at free. v7 removed it because the replay saw no cost, but without it a late double free can free a live block of another task. A free of a block whose page belongs to another task (not the task that runs, and not the host) is a miss: it is counted in `dealloc_miss` and not freed.
- `sumTask` must also cover the JS pages that the task adopted (`adopt`), not only its small and large lists. Check this in the port.

| Test | Expect | Revert check |
|---|---|---|
| String loop in a Roc app, 5,000, 10,000, 80,000 steps | Wasm memory under 6 MB | Old allocator: 79 MB, 202 MB, out of memory |
| `research/alloc/scripts/dfree.mjs`, moved to `bench/` | 3 double frees caught, live blocks differ | Without the check: the same block twice |
| `dfree.mjs`, new case: task A frees a block after its page went back and then to task B | B's block stays live, `dealloc_miss` goes up | Without the owner check: B's block is freed and given out again |
| `fmark.mjs` | A live block that starts with the mark is freed | Without the list check: not freed |
| `reserve.mjs` | A 1 MB block at the memory cap uses the reserve | Without the drain: out of memory |
| `adopt.mjs` | After `freeOwner`, only the host bytes stay | JS slot 0: 12,896 B stay |
| Replay (`research/alloc/replay`) of the port against `v7.zig` | Same memory and copies on all 5 traces. CPU within 3 %. | None: a comparison |
| `bench/node-test.mjs`, the leak test, `wild.mjs` with sum modes 1 and 2 | 0 bad bodies, live bytes 0 | Old allocator: the string-loop row fails |

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

| Gap | Design says (`../DESIGN.md` §6.1, `../DESIGN-REGISTRY.md` §8) | Code has |
|---|---|---|
| G1 | A generic fetch handler | `requires { handle! : Str => Str }` (`platform/main.roc:2`). No method, headers or status. The body must be UTF-8. |
| G2 | A `Worker` capability record (`fetch!`, `d1!`, `r2!`, `cache!`) and a scripted record for unit tests | The app imports `pf.Wait` and uses raw kind numbers (`bench/app.roc:10,14`) |
| G3 | Effect errors are results | Status 0 on any error. JS drops the message (`bench/core.js:466`). |
| G4 | The registry runs a compat bot and ingest | Only the fetch handler |

| Step | Change | Test |
|---|---|---|
| 8a | `Request` (method, url, headers, body bytes) and `Response` (status, headers, body bytes) types. `requires { fetch! : Request, Worker => Response }`. JS encodes them in one js_alloc block, and the host decodes them. | Node: binary body (0x00 to 0xFF) round trip, 100 headers, status 404. Revert to `Str`: the test fails. |
| 8b | Typed effects as Roc functions over `Wait.wait!`: `fetch!`, `d1_query!`, `d1_batch!`, `r2_get!`, `r2_put!`, `kv_get!`, `kv_put!`, `cache_match!`, `cache_put!`. They are fields of the `Worker` record. `Wait` is not in `exposes`. | Each effect against a Node fake of the binding. Revert (a wrong kind number in one effect): its test fails. |
| 8c | A scripted `Worker` record for tests with no host | `roc test` of a handler with a scripted record. Revert (the record calls the host): `roc test` fails. |
| 8d | Effects return `Try(ok, WorkerErr)`. JS writes the error kind and the message in the result block. | io that throws: Roc gets the message. A 404 and a network error give different tags. |
| 8e | More entry points: `scheduled!` (cron) and `queue!` (a batch of messages). A missing one is not exported. | Node: call each entry point. workerd: a cron trigger runs `scheduled!`. Revert (no export): the call fails. |

## 9. JS shim

| Gap | Now |
|---|---|
| G5 | The shim is `bench/core.js`, mixed with test code (`expected`, `check`). `bench/worker.js:621` makes `io` from the `env` of the first request. `io` has no `ctx.waitUntil`, no `request.signal` and no request headers. |

| Step | Change | Test |
|---|---|---|
| 9a | Move the runtime to `js/` (one entry module, for example `js/index.js` that exports `makeHandler(module)`). It returns `{ fetch, scheduled, queue }` for the Worker. Test helpers stay in `bench/`. | `bench/worker.js` and the Node tests use `js/` and still pass |
| 9b | The `io` call gets the task id. The task table (2c) keeps the request context of each task: `env`, `ctx`, the `Request`. | Two requests at the same time with different headers. Each effect sees the headers of its own request. Revert to one shared context: the test fails. |
| 9c | `ctx.waitUntil` as an effect | A `waitUntil` promise runs after the response. Revert (no `waitUntil`): the promise stops with the response. |

## 10. Body handles

| Risk | Now |
|---|---|
| R2 | All bodies go through wasm memory, and wasm memory never gets smaller. A 10 MB R2 object uses 10 MB of the 128 MB isolate limit for the life of the instance (and counts in the memory budget of problem 4). |

| Step | Change | Test |
|---|---|---|
| 10a | JS keeps large bodies (`ReadableStream`, `Response`) in a table, and Roc gets an opaque `Body` id. `Response` can give a `Body` back to JS with no copy into wasm. | Node: send an R2 object of 50 MB through `r2_get!` to the response. wasm memory grows by less than 1 MB. |
| 10b | `body_read!(Body, max)` copies the bytes into wasm only when Roc needs them. Ingest needs only `main.roc` from the archive. | Read the first 1 KB of a 50 MB body: wasm memory grows by less than 1 MB. Revert (copy all): it grows by 50 MB. |
| 10c | The task table frees the body ids of a task at its end, its trap and its cancel (3c) | After 10,000 requests with traps and cancels, the body table is empty. Revert (no free at a trap): it is not empty. |

## 11. Release

| Gap | Now |
|---|---|
| G6 | `platform/targets/` is in `.gitignore`. There is no release workflow, so a user cannot use the platform by URL. |

| Step | Change | Test |
|---|---|---|
| 11a | A release workflow: build the production host (7a) with the pinned nightly (`compat/last-stack-first-nightly`), bundle the platform with `roc bundle`, and attach the bundle and the `js/` package to a GitHub Release | Run on a test tag. A new app builds with the release URL. |
| 11b | Publish `js/` (npm, or a file in the release that the app copies) | A new Worker project uses it with wrangler |
| 11c | An example Worker app with a wrangler config (with the compatibility flag `enable_request_signal`, for 3b), deployed by CI. 5d (CPU limit on the edge) runs on it. Also check what the edge does at 128 MB: is only the isolate stopped, and do the requests in flight fail? |
 The deployed example answers. 5d and the 128 MB check give their results. |

## 12. One instance per isolate: check memory at resume

Goal: one wasm instance per isolate takes all requests (variant B), also after a host bug. Each task sums its memory when it waits. When it resumes after other tasks ran, it sums again. A difference shows that another task wrote into it. Only that task fails. The instance stays when its shared state passes a check.

Why this is now possible: the v7 allocator (6e) keeps each task's memory in its own pages, with a list per task. So the sum reads only the task's bytes (752 KB per wait at 2,000 items), with no heap walk.

Measured against a new instance per request (variant A, many instances per isolate), v7 allocator, 64 requests at once, full app (`research/alloc/README.md`, "CPU: full app" and "Memory, MB"):

| | Variant A | Variant B, check at each resume (the plan) |
|---|---|---|
| 200 items: µs per request, memory | 377, 152 MB | 221 (-41 %), 7.8 MB |
| 2,000 items: same | 2,468, 232 MB (above the 128 MB limit) | 2,110 (-15 %), 52.9 MB |

### What a host bug can damage

Wasm checks bounds only at the edge of linear memory. A wrong store inside it (a host bug, a compiler bug) is not seen. Only one task runs at a time, so the writer is the task that runs.

| Memory | Written by | Check | Now |
|---|---|---|---|
| Task pages and large blocks (Roc values) | The task | Sum at wait, check at resume (12a, 12b) | In the research host |
| Saved stack copy | `waitBegin` | Same: the copy is in the task's pages | In the research host |
| `Wait` record: low, top, copy address and length, owner | `waitBegin` | Add these fields to the sum (12a). Not `out`: JS writes it during the wait. | Not covered |
| Shared stack below the saved part | The task that runs | Not needed: `waitEnd` writes the copy over it | |
| Free units, the page reserve | Nobody | Not needed: the allocator reads only its tables, never a free unit, and sets up a page from the reserve again | |
| Allocator tables (about 26 B per unit, 0.9 MB), task records, page reserve | The allocator, for all tasks | They change at each call, so no sum. Structural check after an alarm (12d). | Not covered |
| Constant data (Roc constants, host constants) | Nobody after `init` | Sum at `init`, check after an alarm (12d) | Not covered |
| Host globals (`TASK_TOP`, `OWNER`, the log, task ids) | The host | Range checks after an alarm (12d) | Not covered |
| Pages of the roc runtime (foreign units) | The roc runtime | 12-pre finds which are constant after `init`. 12d sums those, and range-checks the tables of the others. | Not covered |
| JS blocks written during a wait (the response block) | JS | Not in the sum. JS writes them just before the resume. | Known gap, small window |

### What happens at a resume and after an alarm

```
task T waits:    copy stack ─> sum(T pages + Wait fields) ─> Wait.sum
other tasks run (one of them may write wild)
task T resumes:  other code ran in the instance since T waited?
                   no  ─> resume (nothing could write)
                   yes ─> sum again ─ same ─> resume
                                     └ different ─> ALARM
unclean trap of a task ─────────────────────────> ALARM

ALARM:  the task that trapped, or T, gets a 503; its pages are freed (freeOwner)
        global check (12d) before the next task enters ─┐
instance idle, or N requests since the last check (12e) ┤
                                                        ├ pass ─> instance stays; tasks check at resume as usual
                                                        └ fail ─> cancel all tasks (3c, each gets a 503),
                                                                  drop, new instance (M1)
```

"Other code ran" means any export call since T waited: a task run, a resume, `js_alloc`, `res_free`, `log_clear`, `check_heap` or the idle reset (H2). Each of them runs allocator or host code, so each can write. The host keeps a counter (`RUN_EPOCH`) that goes up at each export call. The `js_alloc` of T's own response block is also such a call, so almost every resume checks.

This answers the old open question 1 (kill all tasks, or let the intact ones finish): the intact ones finish, because their sums show that they are intact.

### Costs (measured, `research/alloc/README.md`, "Benchmarks")

| v7 | 2,000 items | 200 items |
|---|---|---|
| Replay: allocator time, no sums | 74.6 ms per 384 requests | 53.9 ms per 2,560 requests |
| Replay: sum at each wait (`"afterAlarm"`) | +14.1 ms, about +37 µs per request | +11.5 ms, about +4.5 µs per request |
| Replay: also check at each resume (`"always"`) | +30.1 ms, about +78 µs per request | +16.6 ms, about +6.5 µs per request |
| Full app, 64 at once: `"afterAlarm"` against no sums | +3 % | +1 % |
| Full app, 64 at once: `"always"` against no sums | +6 % | +3 % |
| KB summed per wait | 752 | 79 |

The full app costs more than the replay shows, and its runs vary by about 3 %. 12f measures the cost again in the platform.

The sum is Fletcher with SIMD: 66 GB/s, against 12.5 GB/s for wyhash (`research/hash/`, see `research/README.md`). XOR misses swapped words and pairs that cancel.

Wild-write test (20,000 requests, 0.5 % write random words and then trap, `research/alloc/scripts/wild.mjs`). Wrong bodies with status 200:

| Words written | No sums (v0 to v7) | Sums, mode 1 or 2 (v0 to v7) |
|---|---|---|
| 16 | 4 to 39 | 0 |
| 256 | 68 to 358 | 0 |
| 4,096 | 239 to 620 | 0 |

The check is strict: a write into free space inside a task's own page also fails that task. That is correct, because the write shows a bug.

### Gaps

| Gap | Effect | Plan |
|---|---|---|
| A wild write into the writer's own memory | Its body can be wrong | None. Variant A has the same gap. |
| A wild write into the allocator tables, constant data or host globals, with no trap and no sum difference | No alarm. See "Check of shared memory with no alarm" below. | 12e |
| With `"afterAlarm"`: a task resumes onto damage before the writer traps, then sums the damage into its next "good" sum | A wrong body with status 200 | The default is `"always"`, which checks that resume |
| JS blocks written during a wait | Not checked | 12b checks the owner word and the length of the response block at resume |
| A late double free of a small block, after its page went to another task | It frees a live block of that task. Its sum finds this only if the task waits again. | The owner check at free (6e port) |
| Fletcher misses a change | About 2^-64 for random writes | None |

### Check of shared memory with no alarm (decided 2026-10-14)

The sums protect the memory of each task. Shared memory has no owner and no sum, because it changes at each allocation.

| Shared memory | What it holds |
|---|---|
| Allocator tables | Which units are free, which task owns each page |
| Constant data | Roc constants, host constants |
| Host globals | `TASK_TOP`, `OWNER`, the log, task ids |

The global check (12d) reads it. Without 12e, that check runs only after an alarm. So a wild write that changes only shared memory, with no trap, is not found:

```
a bug writes one wrong word into the allocator tables
  -> no trap, no task sum changes -> no alarm
  -> the allocator thinks that a page of task X is free
  -> it gives the page to task Y, and Y writes into it
  -> X waits and resumes: its sum differs -> alarm, X gets a 503   (found)
     X does not wait again: X sends a wrong body, status 200       (not found)
```

Decision: the global check also runs with no alarm, at two times:

| When | Rule | Why |
|---|---|---|
| Idle | When a task ends and no other task runs or waits, JS runs the check in `ctx.waitUntil` of that request. So it runs after the response is sent and does not add to its time. At most once per idle period: not again until a new task ran. | Free: nothing waits for the instance |
| Every N requests | JS counts the requests that started. At N, it runs the check before the next task enters wasm (no task is in wasm then), and starts the count again. Idle checks also start the count again. | A busy instance may never be idle |

N (`heapCheckEvery`):

| Item | Value |
|---|---|
| Rule | The smallest round number that keeps the cost at or below 0.1 % of the CPU time |
| Formula | `check time / (N x median request time) <= 0.001` |
| Check time | Measured by 12d |
| Example | A 1 ms check and 2 ms requests give N = 500 |
| First value | 1,000 |

A failed check acts as a failed check after an alarm: cancel all tasks (each gets a 503), drop the instance, start a new one (M1). Each check writes its time to a counter. Each failed check writes one log line (M11).

### Steps

| Step | Change | Test |
|---|---|---|
| 12-pre | Map the memory of an instance: stack, data segments (constant or not), host `.bss` (allocator tables, task records), heap units, foreign units. Find what is constant after `init`. | A script prints the map of the bench app. Each region is in the table above. |
| 12a | Port the sum at each wait from `research/alloc/harness/host/host.zig:112` to `host/host.zig`, with `sumTask` from v7 (6e). Add the fixed fields of the `Wait` record to the sum. Check that `sumTask` covers the JS pages that the task adopted. | `wild.mjs` with 16, 256, 4,096 words: 0 bad bodies. A test export writes into `Wait.low` of a waiting task: that task gets a 503. Revert (no `Wait` fields): wrong stack restore or a trap that is not clean. A test export writes into an adopted JS block of a waiting task: that task gets a 503. Revert (no JS pages in `sumTask`): no 503. |
| 12a-stack | Test of the stack copy: 64 tasks at depths of 10 to 4,000 frames, with a canary word in each frame. They wait and resume in random order. | All canary words are correct at each resume. Revert (copy one word less): a canary is wrong. |
| 12b | Check at resume when other code ran since the wait (`RUN_EPOCH` goes up at each export call, sum mode 2). Default `resumeCheck: "always"`. Check the owner word and the length of the response block. | A test export writes one word into a waiting task's page, with no trap: that task gets a 503, the others are correct. Revert to `"afterAlarm"`: the task returns a wrong body with status 200. A test export changes the length of a response block during the wait: the task gets a 503. Revert (no block check): the task reads past the block. A `js_alloc` with no task run between: the resume checks. Revert (counter only on task runs): no check. |
| 12d | Global check (export `check_heap`). Units: each is in exactly one place (a free run, a task page list, a large block, the reserve, foreign). The bitmap matches the free runs. Boundary tags match. Each small page's free list has `slots - live` entries. Task lists link back. Constant data and constant foreign units match their sums from `init`. Host globals are in range. Fail: cancel all tasks, drop, new instance (M1). | A test export breaks one table entry of each kind: each is found, and the instance is replaced. Revert (no check): the next requests get blocks that overlap (`dfree.mjs`-style check). Time of the check at 50 MB of heap: target under 1 ms. |
| 12c | Alarm: the task gets a 503, `freeOwner` frees its pages, and JS calls the global check (12d) before the next `handle` or resume. This replaces the retire after an unclean trap in `bench/core.js`. Change the tests of problem 1 that look for a retire (see "Change after 12c"). | `wild.mjs`: 0 bad bodies, the instance count stays 1 while the global check passes. Revert (retire as now): a new instance per alarm. |
| 12e | The global check with no alarm: when idle, and every `heapCheckEvery` requests (see "Check of shared memory with no alarm"). Set the default of `heapCheckEvery` from the time of 12d. | A test export breaks one table entry with no trap, then requests continue: with `heapCheckEvery` 100, the instance is replaced within 100 requests. With only idle checks, it is replaced when the requests stop. Revert (no 12e): the instance is never replaced, and a later request gets a wrong body. CPU cost with the default N: at most 0.1 % (bench of 12f). |
| 12f | Full-app bench on an idle machine: sums off (sum mode 0, bench build only), `"afterAlarm"`, `"always"`, each with the 12e checks on. Write the costs in `bench/README.md`. | None: a measurement |
| 12g | When talon runs on the platform: record its allocator calls (`TRACE=1 research/alloc/build.sh`), replay them against v7 (`research/alloc/scripts/all.sh` with the talon traces), run 12f on talon, and set `heapCheckEvery` from its median request time. Measure H7 and H8 on talon. | None: a measurement |

## Done when

- All tests above pass, and each fails when its change is reverted (the exceptions are in "Order of work").

- `bench/node-test.mjs` and the leak test still give 0 bad bodies and live bytes 0.
- DESIGN.md §6.1, DESIGN-REGISTRY.md §8 and `bench/README.md` show the new rules: stack-first, the task table, cancel, the memory management of problem 4, one instance per isolate with the checks at resume (12), the CPU signals, the platform API (8), the shim (9), body handles (10) and the release (11).
