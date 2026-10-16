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
| 8 | The platform API is not the designed API: `Str => Str` (G1), raw kind numbers (G2), status 0 on all errors (G3), only a fetch handler (G4). The design is now `API.md` (2026-10-15). | The registry cannot take binary uploads, has no types, no error causes and no cron |
| 9 | The JS shim is bench code, and `io` has no request context (G5) | No entry module for users. No `ctx.waitUntil`, `request.signal` or headers in an effect. |
| 10 | All bodies go through wasm memory (R2) | A large R2 object uses wasm memory that never gets smaller |
| 11 | No release (G6) | Nobody can use the platform by URL |
| 12 | After an unclean trap, any part of the instance's memory can be damaged. Today the only answer is a new instance and a drain of the old one. | Two instances in one isolate (memory), and tasks that resume onto damaged memory return wrong bodies with status 200 |

## Order of work

| Order | Items | Depends on |
|---|---|---|
| 1 | 1a, 1a-ci, 1b to 1d (done) | none |
| 2 | 6e, then 6a and 6d (6b and 6c are replaced by 8a) | none. 6e replaces `hostlib/alloc.zig`, so 6a, 6d and 2a change the new file. 6e also fixes B5, which can stop the isolate with ordinary Roc code. 6a corrupts the heap, so it comes next. |
| 3 | 2a to 2d | none |
| 4 | 3a to 3c (3.0 is done) | the task table (2c) |
| 5 | 4-pre, 4a, then 12-pre, 12a, 12a-stack, 12b, 12d, 12c, 12e, 12f, then 4b to 4j (V1 to V4 are done) | the v7 allocator (6e), the task table (2c), cancel (3c), the clean OOM (6d). 12c needs one instance (4a) and the global check (12d). |
| 6 | 5a to 5c. 5d (edge) waits for a deployed worker in 11. | none |
| 7 | 7a to 7c | none. Before 8, because 8 changes the exports. |
| 8 | 9a and 9b, then 8a, 8b with 9c, 8c with 10a and 10b, 8d, 8e (`API.md` phase A). 10c is part of the test of 8a. | the split ABI (7a), the header settings (7b), the task table (2c), cancel (3c). 8a needs the per-task roots and ref table of 9b, and 8b and 8c need `makeHandler` of 9a. |
| 9 | 8f (`API.md` phase B) | 8a to 8e |
| 10 | 8g, local. The edge part runs after 11. | 8a to 8e |
| 11 | 11a to 11c, then 5d on the edge | 7 to 10 |
| 12 | Update DESIGN.md §6.1, Q12 and Q14, DESIGN-REGISTRY.md §8 and `bench/README.md` (API.md RF10) | all |
| 13 | 12g: measure with talon | talon runs on the platform |

Each new test must fail when its change is reverted. Exceptions: moves, releases and edge runs (9a, 11a to 11c, 5d), comparisons (the replay row of 6e) and measurements (8g, 12-pre, 12f, 12g). Their test is that the old tests still pass, or the run gives its numbers.

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
| 10-12 | PASS. 4500: out of bounds, clean (4-pre), instance kept, live bytes 0, next request correct. 4500 alloc: canary trap, clean, instance kept. A cold V8 RangeError (first request, depth 100000) is clean too. V2: a forced trap at normal depth retires the instance. | PASS |
| 10-09 | PASS with the fallback (one instance per request) | PASS (variant b falls back) |
| 10-09, `--no-fallback` | FAIL: bodies at 4500 and 5000 with a broken canary | |

`app_deep.roc` now takes `<depth> alloc`, so the overflow test covers the canary trap. The test computes each expected body in JS. Depths 4500 and 5000 were added: on 10-09 the silent overwrite happens only while the stack is past the canary and still above the data.

Revert checks (each test must fail):

| Revert | Build | Result |
|---|---|---|
| 1c: the canary trap is always clean | 10-09, `--no-fallback` | FAIL: the unclean trap did not retire the instance |
| 1b: `STACK_FIRST = true` | 10-09 | FAIL: the next request traps |
| 1b: `STACK_FIRST = false` | 10-12, `--expect-shared` | FAIL: the runner fell back |
| No retire in `core.js` | 10-12 | FAIL (after 4-pre, with the forced trap at normal depth, V2): the unclean trap did not retire the instance. Before 4-pre it was the overflow at depth 4500. |

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
| 2a | `js_alloc` returns 0 on out of memory and does not trap. JS returns status 4 (API.md 4.1), and the host makes a clean OOM trap for the task. | Test export `fail_next_alloc` (6d) before a `js_alloc`: the task gets a 503, and the other tasks are correct. Revert (trap): the waiting task is lost. |
| 2b | `makeWait` (`bench/core.js:9-27`) puts one try/catch around all the code after it reads the arguments. It always returns a status and never rejects (as Pyodide `suspenders.c` and the wasm-bindgen `catch` imports do). | io that throws synchronously; io that rejects. Both tasks get an error status. Revert (no try/catch): the sync throw skips `waitEnd`, and live bytes stay. |
| 2c | Task table in the host. JS gives each task an id: `handle(p, l, id)`. The host keeps each `Wait` in a table by id. `task_abort(id)` frees the saved copy and calls `freeOwner(id)`, also when `waitEnd` did not run. Problems 3 and 4 use this table. | Force a throw into a waiting task: live bytes return to 0. Revert (no table): live bytes stay. |
| 2d | `TRAP_CLEAN` is set only while a task runs (`OWNER != 0`), and is cleared when `handle` starts | A trap in a host call from JS is unclean. Revert: it is clean. |

### Status of steps 2a, 2b, 2d (2026-10-16)

| Step | State | Where |
|---|---|---|
| 2a | Done | `hostlib/alloc.zig` (`js_alloc` gives 0), `bench/core.js` (`makeWait` returns 4, `enc0` gives null), `host/host.zig` (`roc_wait`, `STATUS_OOM`) |
| 2b | Done | `bench/core.js` (`makeWait`, now exported for the test) |
| 2c | Done. See "Status of step 2c" below. | |
| 2d | Done | `hostlib/mem.zig` (`trapClean`), `host/host.zig` (`handle`) |

How status 4 uses the old wait path (2a): the import `js_wait` and `Wait.wait!` do not change. `js_wait` already gives a `u32` status, so JS returns 4 and `roc_wait` checks it after `waitEnd` (the task is back on its stack and has its owner again) and calls `mem.trapClean()`. Roc code never sees status 4. 8a replaces this with the check of API.md 4.1. The check of status 5 (3c) must go before `waitEnd`, as 3c says.

Tests (nightly 10-12, Node 26.7):

| Step | Test | Result |
|---|---|---|
| 2a | `node bench/oom-test.mjs bench/out/app.wasm`: `fail_next_alloc` in the io of one wait that has a body, so `js_alloc` gives 0 | PASS: that task traps clean (`task_abort` frees its pages), the other 58 requests are correct, live bytes 0, `dealloc_miss` 0 |
| 2a | `node bench/wait-test.mjs bench/out/app.wasm` (`makeWait` alone, `js_alloc` gives 0) | PASS: status 4 |
| 2b | `node bench/wait-test.mjs bench/out/app.wasm`: io that throws, io that rejects, io that gives a Symbol, `js_alloc` that throws (alone, and in the real instance: a JS error in the code after io) | PASS: each gives status 0, no rejection, 0 lost tasks, live bytes 0, 0 waiting tasks, a throw after the block was made frees the block |
| 2d | `node bench/trapclean-test.mjs bench/out/app.wasm`: a failed allocation in `alloc_bench` called from JS, then `task_abort` | PASS: -1 (not clean) |
| 2d | same file: a crash (clean) with no `task_abort`, then a good task, then `task_abort` | PASS: -1 (the flag was cleared at `handle`) |
| 2d | same file: a crash in a task, then `task_abort` | PASS: clean (the bytes freed, not -1) |
| 2d | `bench/oomclean.mjs` (allocator driver): a failed `roc_alloc` and `roc_realloc` with owner 7 and with owner 0 | PASS: clean for owner 7, not clean for owner 0 |
| All | The old tests (list in step 6a) | PASS |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 2a: `js_alloc` traps on 0 (as before) | `oom-test.mjs` | FAIL: the trap is inside makeWait and gives status 0, so the task goes on with an empty body: a bad body and no trap |
| 2a: `roc_wait` does not check status 4 | `oom-test.mjs` | FAIL: same bad body |
| 2b: the old `makeWait` (one try/catch around io only) | `wait-test.mjs` | FAIL: `js_alloc` that throws rejects, the real instance loses a task (1 rejected, live bytes 8,576, 1 waiting task) |
| 2d: `trapClean` always sets the flag | `trapclean-test.mjs`, `oomclean.mjs` | FAIL: `task_abort` gives 0 for the trap from JS, owner 0 gives clean |
| 2d: `handle` does not clear the flag | `trapclean-test.mjs` | FAIL: `task_abort` gives 0 after the good task |

Choices for 2a, 2b and 2d:

| Question | Answer |
|---|---|
| Status of an error in `makeWait` | 0, the status of an io error (G3 is open until 8a). |
| `enc0` (the request block) | `js_alloc` gives 0: the runner returns a trap result for the request and starts no task. Nothing to abort. |
| 2d rule | `mem.trapClean` sets the flag only when `alloc.OWNER != 0`. `mem.zig` imports `alloc.zig` for this (files that import each other, no loop in the declarations). |
| Trap of a host call from JS | The one case today is `alloc_bench`, a bench export. The test uses it with `fail_next_alloc`. |
| What 2c must add | The two-step tests use no task table. The case that needs 2c: a throw into a waiting task from outside `makeWait` (for example the V8 `RangeError` at the resume point). There is no way to make it in a test today. |

Open points found:

| Point | Decision (2026-10-16) | State |
|---|---|---|
| Task slots | The JS task table refuses a new task when all slots of the instance are in use: that request gets a 503 (a shed, M7 step 2), and the instance stays. The `mem.trap()` in `taskOf` stays as a guard, and JS cannot reach it. The host has 254 task slots, not 255: slot 0 is the host and slot 255 is JS. The export `task_slots()` gives the number to JS. | Done in 2c. Test 3 of `tasktable-test.mjs`. |
| OOM in `waitBegin` | A clean trap for the task (M6). A failure of the stack copy frees the `Wait` record first. | Done in 2c. Test 2 of `tasktable-test.mjs`. |

### Status of step 2c (2026-10-16)

| Part | State | Where |
|---|---|---|
| JS gives the task id | Done. `handle(p, l, id)`. The host traps (a guard) on id 0 (the host) and maxInt (the owner of the JS slot). `TASK_IDS` is removed. JS ids: 1 to 0xFFFFFFFE, not reused while in flight. | `host/host.zig` (`handle`), `bench/tasks.js` (`nextId`) |
| `Wait` record by id | Done. `WAITS`: 256 entries, a record at `waitBegin`, out at `waitEnd`. `Wait.owner` is the id, `Wait.at` its index. The fixed fields do not change during the wait (12a can sum them). | `host/host.zig` (`waitAdd`, `waitOf`, `waitForget`, `waitDrop`) |
| `task_abort(id)` | Done. A task with a `Wait` record (a throw at its resume point skipped `waitEnd`): free the record and `freeOwner(id)` (the copy is in the task's pages). It does not touch the stack. Else the old path (the clean flag, `freeOwner(OWNER)`). It now sets the stack pointer to `TASK_TOP` before its calls: `abortFree` has a frame now, and after an overflow the stack pointer is wrapped (V1). | `host/host.zig` (`task_abort`, `abortFree`) |
| `task_cancel(id)` (3c), `task_slots()` | Done | `host/host.zig`, `platform/main.roc` (export list) |
| OOM in `waitBegin` | Done. The record is a host block from `allocHostOrTrap` (OWNER stays the task, so the trap is clean). A failed copy frees the record, then `trapClean`. | `host/host.zig` (`waitBegin`) |
| Slot limit in JS | Done. `begin` gives null when the instance has `task_slots()` tasks in flight. The runner answers `{ status: 503, shed: true }`. | `bench/tasks.js` (`begin`), `bench/core.js` (`run`) |
| Test export `fail_alloc_at(n)` | Added: allocation number `n` from now gives 0. `fail_next_alloc()` is `fail_alloc_at(1)`. `FAIL_NEXT` is now the counter `FAIL_AT`. 7a moves it to the bench list. | `hostlib/alloc.zig`, `host/host.zig`, `bench/alloc_driver.zig` |

Tests (nightly 10-12, Node 26.7): `node bench/tasktable-test.mjs bench/out/app.wasm`.

| # | Test | Result |
|---|---|---|
| 1 | 40 tasks, 5 of them get a throw from the import after a wait of 5 ms, with no status (as a V8 `RangeError` at the resume point). JS calls `task_abort(id)`. | PASS: 5 thrown, 0 unclean, 0 bad bodies, the next request correct, live bytes 0, 0 waiting tasks, 0 saved bytes, `dealloc_miss` 0 |
| 2.1 | `fail_alloc_at(1)` in the io of the first wait (empty body, "select <id>" is a small string): the `Wait` record of the second wait fails | PASS: only the victim traps, its second io never starts, clean (instance kept), live bytes 0 |
| 2.2 | Same with `fail_alloc_at(2)`: the stack copy fails | PASS: same |
| 3 | 400 requests at once, each waits 30 ms | PASS: 254 bodies, 146 sheds (503), the instance stays, the next request correct, live bytes 0 |
| All | The old tests (list in the task) | PASS. `wait-test.mjs` and `trapclean-test.mjs` now give an id to `handle` and `task_abort`. |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| No table: `task_abort` does not look for a `Wait` record | test 1 | FAIL: the victims abort unclean (-1), live bytes, waiting tasks and saved bytes stay |
| The `Wait` record traps unclean on OOM (the old `catch trap()`) | test 2.1 | FAIL: the trap is not clean, the instance is replaced |
| A failed stack copy does not free the `Wait` record | test 2.2 | FAIL: live bytes not 0 (the record stays) |
| A failed stack copy traps unclean | test 2.2 | FAIL: the trap is not clean |
| No slot limit in JS | test 3 | FAIL: the 255th task makes `taskOf` trap unclean, the instance is replaced |

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
| 3b | Each new request first checks the table (it runs in a live request context). The table also keeps the event kind of each task, its start time and the state of its response, and each wait records if it waits on a socket. A task is cancelled (3c) at the deadline of API.md 10.2. A `Fetch` task before `Ctx.respond!` (and a task of a kind with no limit of its own): a wait longer than `taskDeadlineMs` (default 120 s). A `Scheduled`, `Queue` or `Alarm` task: 15 min from its start, the wall time limit of Workers, and no deadline for one wait. After `respond!`: 30 s after the response body is complete, the `waitUntil` limit of Workers. A `Body.writer!` stream is complete at its `close!`, and a 101 response when its socket closes. A wait on a socket (`receive!`, `Tcp.read!`): no deadline. Also cancel at once on `request.signal`, on the close of the socket of the task, and on the cancel of its response stream. 3.0: `request.signal` fires only with the compatibility flag `enable_request_signal`, so the shim documents the flag and 11c sets it. The 15 min and 30 s limits are constants of the shim. A test can make them smaller. | Node: deadline 100 ms, io that never resolves for one request. The next request cancels it: it gets a 503, and live bytes return to 0. Abort the signal of a waiting request: it is cancelled at once. Revert (no check of the table): live bytes stay. A `Scheduled` task and a `Queue` task with one wait of 300 ms end with `Done`. With the task limit set to 200 ms, each is cancelled. Revert (the 100 ms wait deadline for all kinds): they are cancelled at 100 ms. A `Fetch` task that waits 300 ms in `receive!` is not cancelled. Revert (a socket wait has the deadline): it is. After `respond!` (the 30 s limit set to 100 ms): a task with a `Bytes` body that then waits 300 ms is cancelled. A task that writes a `Body.writer!` stream for 300 ms is not cancelled, and a wait that starts after its `close!` is cancelled 100 ms later. Revert (the limit starts at `respond!`): the writer task is cancelled at 100 ms. A 101 task stays while its socket is open for 300 ms, and ends when the socket closes. The client cancels a `Body.writer!` stream: the task is cancelled at once. Revert (no cancel on the stream): it waits until its deadline. |
| 3c | Cancel (`task_cancel(id)`): the host frees the saved copy and calls `freeOwner(id)`. Then the import wrapper must end the suspended stack, because a suspended JSPI stack is never freed and keeps its instance (3.0). The wrapper waits on `Promise.race([io, cancelPromise])`. On cancel, it returns status 5, "cancelled" (API.md 4.1). The host checks this status first, before it reads or writes memory or a global, and runs `unreachable`. The trap ends the stack. JS knows that the task was cancelled, so this trap is not an alarm. A replace (M1) cancels all tasks of the old instance in the same way, so the old instance can be collected. | Node: io that never resolves for some ids. Expect live bytes 0, the other requests correct, and flat memory (RSS too) over 10,000 cancels. Replace an instance with 10 waiting tasks (`--expose-gc`): the `FinalizationRegistry` callback reports the old instance collected. Revert (a promise that never settles, as before): RSS grows by about 6 KB per cancel, and the old instance is not collected. |
| 3d | Removed (2026-10-14): no instance drains (problem 12) | |

### Status of steps 3a to 3c (2026-10-16)

| Step | State | Where |
|---|---|---|
| 3a | Done. One entry for each task in flight: `id`, `inst`, `kind`, `startedAt`, `waiting`, `waitingSince`, `socketWait`, `response` (`none`, `open`, `complete`), `completeAt`, `cancelled`, `reason`, `hostFreed`, `ended5`, `wake` (the cancel promise of the wait). It knows no wasm, so 8a and 9a can use it as it is (9b adds the context of a task). | `bench/tasks.js` (`makeTaskTable`) |
| 3b | Done for the rules that the current code can reach. The other rules are in the table, with unit tests. `deadlineOf(t)` is a pure function of the entry and the deadlines. `sweep()` runs first in each `run`. `request.signal`: `run(req, { signal })`, and `bench/worker.js` passes `req.signal`. The deadlines are options of `makeRunner` (`taskDeadlineMs`, `wallMs`, `initMs`, `afterRespondMs`). | `bench/tasks.js` (`DEADLINES`, `deadlineOf`, `sweep`, `begin`, `respond`, `bodyComplete`, `cancel`), `bench/core.js` (`run`), `bench/worker.js`, `bench/config-s.capnp` (the flag `enable_request_signal`) |
| 3c | Done. `task_cancel(id)` frees the `Wait` record and calls `freeOwner(id)`. JS calls it at the cancel of a task that waits (`onCancel`), else at its next wait. The import waits on `Promise.race([io, cancel])` and gives status 5. The host checks status 5 first after `js_wait` and runs `unreachable` (inline asm, so no memory or global access can move before it; checked in the disassembly: the compare is the first instruction after each `call js_wait`). The runner knows the trap is a cancel (`ended5`): no `task_abort`, not counted as a trap, the request gets a 503 with `cancelled: <reason>`. `runner.replace()` (M1) cancels all tasks of the old instance. The unclean-trap path uses it. | `host/host.zig` (`task_cancel`, `trapIfCancelled`, `roc_wait`), `bench/core.js` (`makeWait`, `hostCancel`, `end5`, `replace`), `bench/tasks.js` (`cancelAll`) |

Tests (nightly 10-12, Node 26.7, workerd of wrangler in Node 26.7):

| Step | Test | Result |
|---|---|---|
| 3a, 3b | `node bench/tasks-test.mjs`: the table alone, fake clock, deadlines 100 ms (wait), 200 ms (wall), 150 ms (Init), 100 ms (after respond). Each row of the deadline table of API.md 10.2: Fetch, Scheduled, Queue, Alarm, Init, Email, Tail, Rpc, EntrypointFetch, after `respond!`, `Body.writer!` open and closed, 101 open and closed, socket waits in 3 states, `request.signal` (before and during the task, not after), socket close and stream cancel, `cancelAll`, slots, ids | PASS: 38 of 38 rows |
| 3b | `node bench/deadline-test.mjs bench/out/app.wasm`, 1: `taskDeadlineMs` 100, io that never resolves. The next request cancels it. | PASS: 503 `deadline`, the next request correct, live bytes 0, 0 waiting tasks, 0 traps, no replace |
| 3b | same, 2: abort the signal of a waiting request | PASS: 503 `signal` after 0.3 ms, live bytes 0 |
| 3b | same, 3: a `Scheduled` task and a `Queue` task (the `kind` of the table) with one wait of 300 ms, wait deadline 100 ms, requests every 25 ms | PASS: both end with a correct body at 302 ms. With `wallMs` 200: cancelled at 209 to 210 ms. A `Fetch` task: cancelled at 118 ms. |
| 3b, 3c | `WORKERD=<workerd> node bench/signal-workerd.mjs` (`bench/config-s.capnp`): 20 requests whose fetch answers after 10 min, the client resets each socket (TCP RST) after 300 ms | PASS: 20 cancels by the signal, 0 waiting tasks, live bytes 0, 20 good requests before and 20 after correct, 0 traps |
| 3c | `node --expose-gc bench/cancel-test.mjs bench/out/app.wasm`, 1: 300 batches of 100 tasks whose io never resolves, aborted while they wait, and 10 good tasks that start right after the abort (they reuse the freed wait records). One more task waits for the whole run, so the page of the wait records stays in the host. RSS after `gc()`, over the last 10,000 cancels | PASS: 30,000 cancels, 0 bad bodies, live bytes 0, 0 traps. RSS 136.2 MB to 137.9 MB: 0.14 to 0.22 KB per cancel (4 runs). 30,000 cancels and 3,000 good requests in about 2 s. |
| 3c | same, 2: replace an instance with 10 waiting tasks | PASS: 10 times 503 `replace`, the `FinalizationRegistry` callback reports the old instance collected after the first `gc()` (50 ms), the new instance is correct |
| All | The old tests (list in the task), and the workerd leak test (`bench.mjs leak 2000 0.01`, variants a and b) | PASS |

RSS of `cancel-test.mjs` 1, more data:

| Run | RSS |
|---|---|
| Measured from batch 10 (the first plan of the test) | 3.25 KB per cancel. It is the warm-up: 71 MB at batch 10, 130 MB at batch 300, 127.5 MB at batch 600. |
| Control: the same batches, no abort (the tasks end) | 112.8 MB to 125.0 MB over the last 10,000 requests (1.25 KB per request): the same warm-up |
| Revert: a promise that never settles (below) | 4.4 to 4.7 KB per cancel (213 MB to 259 MB) |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 3b: `run` does not call `sweep` | `deadline-test.mjs` | FAIL: the task is not cancelled, live bytes and the waiting task stay. Scheduled, Queue and Fetch end at 301 ms. |
| 3b: no `request.signal` in the table | `deadline-test.mjs`, `tasks-test.mjs` | FAIL: not cancelled, live bytes stay |
| 3b: no `request.signal` in `bench/worker.js` | `signal-workerd.mjs` | FAIL: 0 cancels, 20 waiting tasks, live bytes 1,277,120 |
| 3b: the 100 ms wait deadline for all kinds | `deadline-test.mjs`, `tasks-test.mjs` | FAIL: Scheduled and Queue cancelled at 119 ms |
| 3b: a socket wait has the deadline | `tasks-test.mjs` | FAIL: the 3 socket rows are cancelled |
| 3b: the 30 s limit starts at `respond!` (also for an open stream) | `tasks-test.mjs` | FAIL: the writer task is cancelled at 100 ms |
| 3c: a promise that never settles: at a cancel the host frees the task and the runner answers 503, but the import never returns (as before 3c) | `cancel-test.mjs` | FAIL: RSS grows by 4.4 KB per cancel, the old instance is not collected in 5 s |
| 3c: the host does not check status 5 | `cancel-test.mjs` | FAIL: the cancelled tasks run `waitEnd` on the freed records that the new tasks now use: 10 bad bodies in the first batch, an unclean trap, a replace |
| 3c: `task_cancel` frees nothing | `deadline-test.mjs`, `cancel-test.mjs` | FAIL: live bytes and waiting tasks stay. The host slots fill up, and batch 3 fails. |
| 3c: a replace does not cancel the tasks of the old instance | `cancel-test.mjs` 2 | FAIL: the 10 tasks get no 503, the old instance is not collected |

The first version of `cancel-test.mjs` did not catch the revert "the host does not check status 5": each freed record was alone on its page, so the page went back to the reserve, the stale pointer pointed into other data, and `waitEnd` trapped by chance. The anchor task and the start of new tasks right after the abort make the reuse sure.

PLAN tests of 3b that wait for later steps (the table logic is in `bench/tasks.js` and has a unit test now):

| PLAN test | Needs |
|---|---|
| A `Scheduled` and a `Queue` task end with `Done` (today: the `kind` of the table and the body) | 8b (events, `Outcome`) |
| A `Fetch` task that waits 300 ms in `receive!` is not cancelled; revert (a socket wait has the deadline) | 8f (`WebSocket.receive!`), and the import must say that a wait is on a socket (`waitStart(t, true)`) |
| After `respond!` (30 s limit at 100 ms): a `Bytes` body, then a wait of 300 ms, is cancelled | 8b (`Ctx.respond!`), which calls `tasks.respond(t)` |
| A `Body.writer!` stream for 300 ms is not cancelled, a wait after `close!` is cancelled 100 ms later; revert (the limit starts at `respond!`) | 8b (`Body.writer!`): `respond(t, true)`, then `bodyComplete(t)` at `close!` |
| A 101 task stays while its socket is open, and ends when it closes | 8f (`WebSocket.accept!`): `respond(t, true)`, `bodyComplete(t)` at the close |
| The client cancels a `Body.writer!` stream: the task is cancelled at once; revert (no cancel on the stream) | 8b: `cancel(t, 'stream')` from the `cancel` of the stream |
| The close of the socket of the task cancels it | 8f: `cancel(t, 'socket')` |
| The `Init` deadline of 30 s | 8f (`init!` of an object). API.md 10.2 gives it, so the table has `initMs`. |
| Edge facts of API.md 10.2 | 11c |

Choices for 3a to 3c:

| Question | Answer |
|---|---|
| How the import knows its task | The host gives the id as a 10th argument of `js_wait` (`OWNER` before `waitBegin`). JS cannot know which suspended stack resumes: JSPI resumes in promise-job order, and other jobs run between the end of an import and its resume. See the open questions. |
| When the host frees a cancelled task | At the cancel, when the task waits (the table calls `onCancel`). Else at its next wait, in the import, before it returns 5. Once only (`hostFreed`). So the memory is free at once, for example for the request whose check found the deadline. |
| What JS does after a cancel trap | No `task_abort` (the host freed the task already, and the trap changed no state), no alarm, no replace. The request gets a 503. |
| Task that is cancelled while it runs, and ends with no further wait | It keeps its body. The cancel only stops a wait. |
| When the deadlines are checked | At the start of each `run` only (3.0: the timers of a dropped request do not fire). No timer. |
| After `respond!`, while a `Body.writer!` stream or a 101 socket is open | No deadline: API.md 10.2 gives only "30 s after the response body is complete". The signal, the stream cancel and the socket close still end the task. |
| A socket wait | No deadline in any state, also over the 15 min of `Scheduled` and the 30 s after `respond!` (API.md 10.2: "in any state"). |
| `kind` today | `run(req, { kind })`, only a field of the table. 8b sets it from the event. Default `Fetch`. |
| `bench/worker.js` | Passes `req.signal`, and answers a shed or a cancel with its status 503 (it was 500 for all traps). `/stats` gives `cancels` by reason. |
| `bench/echo.js` | An id that starts with `hang` answers after 10 min (a timer, so workerd does not end the request as hung). |
| `bench/config-s.capnp` | Variant b with `enable_request_signal`, on port 8132 |

Open questions:

| Question | Detail | State |
|---|---|---|
| API.md 4.1: "The import has no task argument. JS knows the task that runs." | JS knows the task at `handle`, but not at a resume: which stack resumes depends on the order of promise jobs, and other jobs can run first. Today the host gives the id as an argument of `js_wait`. 8a must keep an id argument for `js_await` and `js_call`, or change API.md 4.1. | Settled 2026-10-16: API.md 4.1 changed, `js_await` takes `task_id` first. |
| `task_slots` in the production list of 7a | JS needs it. 7a lists `task_cancel` but not `task_slots`. | Settled: added to 7a. |
| An unclean trap keeps its host slot | `task_abort` gives -1 and does not call `freeOwner`, so the task slot of that task stays in use in the host, while JS frees its slot at the end of `run`. Today the instance is replaced, so this has no effect. After 12c the instance stays: then JS and the host count differently, and `taskOf` can trap again. 12c must free the slot (or JS must count it as used). | Settled: 12c frees the slot (12c row). |
| A wait that never settles after `respond!` while a stream is open | Only the signal or the stream cancel ends it (no deadline in API.md 10.2). Is that wanted? | Open. The edge run of 11c checks how Workers ends such a request, then API.md 10.2 decides. |


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

### Shim options (`makeHandler(module, opts)`)

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
| `taskDeadlineMs` | 120,000 | 3b. A wait of a `Fetch` task before `Ctx.respond!` (and of a kind with no Workers limit) that is longer is cancelled. `Scheduled`, `Queue` and `Alarm` tasks, the time after `respond!` and socket waits have other deadlines (API.md 10.2). |
| `pinLimit` | 1,000 | API.md RS2: the number of entries in the pin table |
| `ops` | none | API.md 6.4: JS functions of the app, the root `ops` |
| `other` | none | API.md 10.1: Workers handler names that give the event `Other` |

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


### Status of steps 4-pre, 4a (2026-10-16)

| Step | State | Where |
|---|---|---|
| 4-pre | Done | `host/host.zig` (`task_abort(id, rangeError)` reads the stack pointer first), `hostlib/canary.zig` (`overflowed`), `bench/core.js` (`isStackError`), test export `fault_next_wait(kind)` (`host/host.zig`, `platform/main.roc`; 7a moves it to the bench list), `bench/overflow-test.mjs` |
| 4a | Done. The code was already there: 3c made the runner one instance with `replace()`, and the old drain ("tasks that wait on the old one finish there") was gone. There is no pool, no "up to 16" and no 32 MB retire left in `bench/core.js`. 4a adds the test, and `liveInstances()` in the task table. | `bench/oneinstance-test.mjs`, `bench/tasks.js` (`liveInstances`) |

The rule of 4-pre: `task_abort` makes the trap clean when a task ran (`TASK_TOP != 0`, `OWNER != 0`), the layout is stack-first and one of these holds:

| Sign of an overflow | Source |
|---|---|
| The stack pointer is below `STACK_LIMIT` (canary or address 0) or above `TASK_TOP` (wrapped under 0) | The stack pointer at the start of `task_abort`, before `setSP(TASK_TOP)`. Warm code: out-of-bounds trap with a wrapped pointer (V1). |
| JS got a V8 `RangeError` with "call stack" in the message | The second argument of `task_abort`. Cold code: the engine stack ends first and the stack pointer is a normal value (measured 48,672 at depth 4500 to 1,000,000; the pointer "can be anywhere", V1), so only JS can tell. |

Tests (nightly 10-12, Node 26.7):

| Step | Test | Result |
|---|---|---|
| 4-pre | `node bench/overflow-test.mjs bench/out/app_deep.wasm --expect-shared`: depth 4500, no alloc (out of bounds): clean, instance kept, live bytes 0, next request correct. Depth 4500 alloc (canary): same. | PASS |
| 4-pre | same, a cold RangeError: the first request of a fresh module (before any other run), depth 100000 | PASS: `RangeError: Maximum call stack size exceeded`, clean, instance kept, live bytes 0, next request correct |
| 4-pre | same, V2: `fault_next_wait(1)` (out-of-bounds write at normal depth) and `fault_next_wait(2)` (`unreachable`) | PASS: both unclean, the instance is replaced, the next request is correct |
| 4a | `node bench/oneinstance-test.mjs bench/out/app.wasm`, part 1 (variant b): 1,000 requests, 25 at a time, every 100th makes an unclean trap (`fault_next_wait(1)`), then the runner replaces the instance while the other tasks of the wave wait | PASS: max 1 instance with a task (sampled at each wait and each start), 0 bad bodies, 10 own traps, 10 replaces, 367 tasks cancelled by a replace (503 `replace`), 0 other ends, table empty, live bytes 0 |
| 4a | same, part 2 (variant a, the fallback): 1,000 requests with 1 % clean traps | PASS: 0 bad bodies, 10 traps, table empty |
| 10-09 (data-first) | `overflow-test.mjs bench/out09/app_deep.wasm`, `node-test.mjs bench/out09/app.wasm`, `oneinstance-test.mjs` (part 1 is skipped: the runner falls back) | PASS: one instance per request. `overflow-test.mjs --no-fallback`: FAIL (bodies at 4500 and later with a broken canary, and the cold RangeError retired the instance) |
| All | The old tests (list in the task), also `signal-workerd.mjs` | PASS |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 4-pre: `overflowed` always false | `overflow-test.mjs` | FAIL: depth 4500 retired the instance, and the unclean count is 1 |
| 4-pre: JS passes no RangeError flag | `overflow-test.mjs` | FAIL: the cold RangeError retired the instance |
| 4-pre: `overflowed` always true (each trap of a task is clean) | `overflow-test.mjs` | FAIL: the 2 V2 traps did not retire the instance |
| 4a: a replace does not cancel the tasks of the old instance (the old drain) | `oneinstance-test.mjs` | FAIL: 2 instances with tasks at one time, and no task cancelled |
| 4a: no replace after an unclean trap | `oneinstance-test.mjs` | FAIL: 0 replaces (want 10), live bytes 46,240 at the end |
| No retire in `core.js` (step 1 row) | `overflow-test.mjs` | FAIL: the V2 trap did not retire the instance |

Choices for 4-pre and 4a:

| Question | Answer |
|---|---|
| RangeError | The plan says 4-pre counts a V8 `RangeError` as clean (V1 table), but a cold RangeError leaves a normal stack pointer, so the host cannot see it. Smallest choice: `task_abort` takes a second argument, `1` when JS got a stack `RangeError`. An old caller with one argument passes 0. Only for a stack-first build. |
| A trap in a host call from JS (no task: `TASK_TOP` 0, `OWNER` 0) | Not changed: unclean. |
| Test of the V1 RangeError | The cold case needs the first run of the module in the process (warm code traps out of bounds), so the test does it first. It fails when the error is not a `RangeError`, because it would prove nothing. |
| `fault_next_wait(kind)` | A test export, as `fail_next_alloc`: the next `roc_wait` traps at its start. 1: out-of-bounds write. 2: `unreachable`. 3: `unreachable` with a wrapped stack pointer (used by 5c). |
| Unclean traps in the 4a test | `fault_next_wait(1)` set just before the `run` of the victim: JS runs the task up to its first wait inside that call, so the fault hits the victim. The victim is in the middle of a wave, so the other tasks of the wave still wait at the replace. |
| "Instances with tasks" | `liveInstances()`: instances with a task that is not cancelled. A cancelled task stays in the table until its `run` ends. |

Open points of 4-pre:

| Point | Detail |
|---|---|
| Free path and the canary | Settled (2026-10-16, with 12b): `roc_dealloc` calls `canary.check()` first, so an overflow traps before the free changes a table. Test: the free mode of `overflow-test.mjs`. The internal frees of the host (`hostDealloc`) have no check: they run in host frames at a known depth. |

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

### Status of steps 5a to 5c (2026-10-16)

| Step | State | Where |
|---|---|---|
| 5a | Done | `hostlib/cpu.zig` (`export var __instance_signal`, `__instance_terminated`, start value 0xFFFF), `hostlib/root.zig`, `platform/main.roc` (export list) |
| 5b | Done | `hostlib/cpu.zig` (`check`, `trap_cause`), `hostlib/alloc.zig` (`roc_alloc`, `roc_realloc`), `host/host.zig` (`waitBegin`, `handle` clears the cause), `bench/core.js` (`trap_cause` after `task_abort`, result `{ status: 503, cause: 'cpu' }`, `stats.cpu`) |
| 5c | Done, in JS | `bench/core.js` (`readFlag`, check at the start of `run`, then `runner.replace('terminated')`, `stats.terminated`) |

Shim form (read in a workerd checkout of the earlier session, `src/workerd/io/wasm-instantiate-shim.js`, commit `fe4ed9a`; the PLAN cites `1fa5622`): the export must be a `WebAssembly.Global` (`instanceof`), `.value` is the address, and the module must have an exported or imported memory. At registration workerd checks that address + 4 is in memory, and writes 0 to the signal address (a stale signal). It does not write the terminated address. The `workerd 2026-10-12` binary has the shim. A Zig `export var` gives exactly this: a global with the address of the variable (checked in the export section).

Tests (nightly 10-12, Node 26.7, workerd 2026-10-12): `node bench/cpu-test.mjs` (`bench/out/*.wasm`), `WORKERD=<workerd> node bench/signal-workerd.mjs`.

| Step | Test | Result |
|---|---|---|
| 5a | `WebAssembly.Module.exports` of `app`, `app_deep`, `app_strloop`, `app_wait`: both names have kind `global`, the value is a 4-aligned address in memory, the two addresses differ, the u32 there is 0xFFFF | PASS (4 builds) |
| 5a | `signal-workerd.mjs`: `/stats` reads both u32 in workerd | PASS: signal 0 (workerd registered the instance and zeroed it), terminated 65535 |
| 5b A | `app_strloop`, signal 24 written before the request, no wait in the app: the allocation check alone | PASS: 503, cause `cpu`, live bytes 0, instance kept, next request correct after the signal is cleared |
| 5b B | `app_wait` (one wait, no allocation by the app), signal 24 before the request: the `waitBegin` check alone | PASS: same |
| 5b C | `app.wasm`, 30 tasks wait, the io of one victim writes 24 and the test clears it after the victim ends | PASS: the victim 503 `cpu`, the 30 other tasks that resumed while it was set also 503 `cpu` (the signal is for the instance), 0 bad bodies, 0 unclean traps, instance kept, live bytes 0, 0 waiting tasks, 30 requests after the clear all correct |
| 5c | `app_deep.wasm`: a task trapped with a wrapped stack pointer (`fault_next_wait(3)`), no `task_abort`, flag 1 written. Control: no flag, no replace. | PASS: the next request is correct on a new instance, 1 replace, no second replace, the new instance starts with 0xFFFF |
| All | The old tests, `bench/oneinstance-test.mjs`, the 10-09 fallback | PASS |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 5a: the two names are not in the export list of `platform/main.roc` | `cpu-test.mjs` | FAIL: not exported as globals (4 builds) |
| 5a: the same | `signal-workerd.mjs` | FAIL: signal null, terminated null |
| 5a: start value 0 for the signal | `cpu-test.mjs` | FAIL: starts as 0, want 65535 |
| 5b: no check in `roc_alloc` and `roc_realloc` | `cpu-test.mjs` | FAIL in A: the request ran to its end. B and C still trap (the `waitBegin` check). |
| 5b: no check in `waitBegin` | `cpu-test.mjs` | FAIL in B: the request ran to its end. A and C trap at the allocation. |
| 5b: no check in both | `cpu-test.mjs` | FAIL in A, B and C |
| 5b: JS does not read `trap_cause` | `cpu-test.mjs` | FAIL: status and cause are undefined in A, B and C |
| 5c: no check of the terminated flag in `run` | `cpu-test.mjs` | FAIL: the next request threw `memory access out of bounds` (the stale stack pointer) |

Choices for 5a to 5c:

| Question | Answer |
|---|---|
| Which values are "set" | Signal: exactly 24 (SIGXCPU). Terminated: exactly 1. 0 and 0xFFFF are not set. The plan gives these values only. |
| Where the signal is checked | `roc_alloc`, `roc_realloc` (the app's allocations) and `waitBegin`. Not in `hostAllocFor`: a host allocation (the Wait record, the stack copy) in `waitBegin` would then hide a missing `waitBegin` check, and no test could fail. A host call from JS (`OWNER` 0, no task) never traps on the signal. |
| Cause to JS | The new export `trap_cause()`: 1 after a clean trap from the signal, then 0. `handle` clears it. In the production list of 7a. For variant a (no `task_abort`), the runner reads it in the catch. |
| 5c in JS | The plan allows JS before `handle` or the host. JS: `readFlag` at the start of `run`, before the deadlines sweep, so the old tasks are cancelled with `replace('terminated')` (they get a 503). Cost: one `DataView` read for each request. Variant a needs no check: each request has a new instance. |
| Who clears the signal | The runtime ("then 0 to clear it", table above). The host does not. The tests clear it by hand. If the runtime never clears it, each task of the instance traps on its next allocation. |
| `app_wait.roc` | New bench app: one wait, no allocation. `bench/build.sh` builds it. It is the only way to test the `waitBegin` check alone (`app_deep` allocates before its first wait). |
| Stale state in the 5c test | `fault_next_wait(3)`: the task traps with a wrapped stack pointer. The plan says "stale `TASK_TOP`", but a stale `TASK_TOP` alone does not make the next request fail (`handle` sets it again). A real CPU kill can leave any state. |
| `/stats` of `bench/worker.js` | Also gives `signal` and `terminated` (null when the export is missing). |

Open points of 5a to 5c:

| Point | Detail |
|---|---|
| Does the runtime clear the signal? | The source (`tracked-wasm-instance.c++`) has `clearShutdownSignal`, but no caller is in open-source workerd. 5d must show when the signal returns to 0 on the edge. |
| What if the signal comes while a task waits and it does not allocate or wait again | It runs to its end. The check only runs at an allocation and at a wait. |

## 6. Host bugs (second audit)

| Bug | Where | Now |
|---|---|---|
| B1 | `hostlib/roc.zig:13-19`, `hostlib/wordbuf.zig:13-15`, `hostlib/alloc.zig:177` | `logPushCopy` and the growth of the `LOG` buffer allocate with `OWNER` = the task that runs. No JS code calls `log_ptr`, `log_len` or `log_clear`. After a clean trap, `freeOwner` frees the buffer and its entries while `LOG.ptr` still points to them. The next `dbg` writes into a freed span that can be in use by another task. Each `dbg` also leaks, because nothing drains the log. Fixed in 6a (2026-10-16). |
| B2 | `host/host.zig:114,121,123` | The import `js_wait` takes `num` as an `f64` (`@floatFromInt`). Values above 2^53 change with no error. |
| B3 | `bench/core.js:12-13` | `makeWait` reads `a` and `b`, but not `c` (bytes) or `num`. |
| B4 | `hostlib/alloc.zig:219-231` | `roc_alloc` and `roc_realloc` return 0 to Roc when memory cannot grow. Address 0 is the bottom of the stack. Today `memory.grow` does not fail before the isolate is stopped. With `js_grow` (4b) it can fail. Fixed in 6d (2026-10-16): both trap clean on 0. |
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
| 6b | Replaced by 8a (2026-10-15): the new ABI has no `num`. Draft: the import takes `num` as `i64`. JS gets a `BigInt` (JS BigInt integration). | io that echoes `num` as text, with 2^53 + 1 and 2^64 - 1. Revert: the echo is wrong. |
| 6c | Replaced by 8a (2026-10-15): the new ABI has no `a`, `b`, `c`. Draft: `makeWait` reads `cp, cl` as bytes and `num` before its first `await`, and gives them to `io`. | io that echoes `c`, with bytes that are not UTF-8 (0x00 to 0xFF). Revert: the bytes are not passed. |
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

### Status of step 6e (2026-10-16)

| Part of the port | State | Where |
|---|---|---|
| v7 without the research switches | Done. Removed: `set_keep_empty`, `set_page_cache`, `set_cache_max`, `set_cache_drain`, `set_place`, `set_grow_at_top`, `set_grow_chunks`, and the research counters (`cache_drains`, `heap_grows`, `small_pages_taken`, `grown_in_place`, `free_mark`, `mark_false`, `TASK_OVERFLOW`, `LEAKED_AT_END`, `SUM_BYTES`, `sumOwner`). | `hostlib/alloc.zig` |
| Defaults | Kept: empty page back at once, reserve of 256 pages drained only when memory cannot grow, moved block to a 2x run, grow at the top first | `smallGive`, `cacheDrain`, `takeRun`, `hostRealloc` |
| `poolGrow` is the only grow | Done. It calls `memory.grow`. 4b adds `js_grow`. | `poolGrow` |
| `TRACK_LIVE`, `LIVE_BYTES` | Kept | |
| Owner check at free | Done. A free is allowed for a block of the host (slot 0), of JS (the JS slot) or of the task that runs. Else it is counted in `dealloc_miss` and not freed. | `mayFree`, `hostDealloc` |
| `set_free_mark` | Done. JS sets a random odd mark for each instance. | `hostlib/alloc.zig`, `platform/main.roc`, `bench/core.js` |
| `sumTask` covers adopted JS blocks | Done in the allocator (`sumAdopted`: a walk of the JS pages, as `freeAdopted`). The host does not call `sumTask` yet: 12a does. | `hostlib/alloc.zig` |
| Host | `handle` calls `taskEnd` at the end (the task slot and pages go back). The response block and the `Wait` record are host blocks (owner 0). `heap_fill` frees its blocks as their owner. | `host/host.zig` |

Tests (nightly 10-12, Node 26.7):

| Test | Command | Result |
|---|---|---|
| String loop, 5,000, 10,000, 80,000 steps | `node bench/strloop-test.mjs bench/out/app_strloop.wasm` (app `bench/app_strloop.roc`, built by `bench/build.sh`) | PASS: 2.3, 2.4, 5.0 MB. Bodies correct, live bytes 0. |
| `dfree.mjs` case 1 | `bench/alloc-test.sh` (builds `bench/out/alloc_driver.wasm` from `hostlib/` with `bench/alloc_driver.zig`, then runs the 5 scripts below) | PASS: 3 of 3 caught, 3 different live blocks |
| `dfree.mjs` case 2 (new): task A frees after its page went to task B | same | PASS for 24 B and 2,000 B: B's block stays live, `dealloc_miss` 0 to 1 |
| `fmark.mjs` | same | PASS: 3 of 3 sizes freed and used again, 0 double frees counted |
| `reserve.mjs` | same | PASS: memory full at 128 MB after 1,994 blocks of 64 KB, the 1 MB block gets the reserve |
| `adopt.mjs` | same | PASS: 48 B stay (the block of task 8) |
| `sumjs.mjs` (new): a byte changed in an adopted JS block changes the task's sum | same | PASS: small and large block change the sum. A block of another task does not. |
| `bench/node-test.mjs` | `node bench/node-test.mjs bench/out/app.wasm` | PASS: 0 bad bodies, live bytes 0, both variants. `dealloc_miss` stays 0 (also with 300 requests at once, 200 and 2,000 items). |
| Leak test | `WORKERD=<workerd 2026-10-12> node bench/bench.mjs leak 10000 0.01` | PASS: variants A and B, trap rate 0.01 and 0: 0 bad bodies, 0 errors, live bytes 0 |
| `wild.mjs`, sum modes 1 and 2 | Needs the sum at each wait and the wild-write hook in `host/host.zig` (12a). Run instead in the research harness with the port: `research/alloc/build.sh port`, `SUM=<m> node scripts/wild.mjs port <words> 20000 0.005 20` | Sum 1 and 2, 16, 256, 4,096 words: 0 wrong bodies. Sum 0: 24, 302, 314 (as expected with no sums). |
| `bench/overflow-test.mjs` | `node bench/overflow-test.mjs bench/out/app_deep.wasm [--expect-shared]` | PASS |

`handle` calls `taskEnd`, so "live bytes 0" holds also when a task leaks. Check: a build that adds the bytes that `taskEnd` frees back to `LIVE_BYTES` gives live bytes 0 in `node-test.mjs` and `strloop-test.mjs`. So no task leaks today.

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| Old allocator (all of 6e reverted) | `strloop-test.mjs` | FAIL: 76.9 MB at 5,000 steps, 321.1 MB at 10,000, out-of-bounds trap at 80,000 (B4) |
| No double-free check (`smallFree` never looks for the mark) | `dfree.mjs` case 1 | FAIL: the same block twice, 3 of 3 sizes |
| No owner check (`mayFree` always true) | `dfree.mjs` case 2 | FAIL: B's block is freed and given out again, `dealloc_miss` stays 0 |
| No free-list check (each mark match is a double free) | `fmark.mjs` | FAIL: not freed, 3 of 3 sizes |
| No drain of the reserve | `reserve.mjs` | FAIL: out of memory |
| JS slot 0 (the JS task record has slot 0) | `adopt.mjs` | FAIL: 12,896 B stay. `sumjs.mjs` also fails. |
| No JS blocks in `sumTask` | `sumjs.mjs` | FAIL: the sum does not change |

Replay of the port against `v7.zig` (`research/alloc/replay/build.sh v7 port`, `node scripts/replay.mjs <trace> <reps> v7 port`, both orders). Memory, peak of pages, copies and MB copied are equal on all 5 traces. CPU: the mean of the runs, ms per trace, no sums:

| Trace | Reps | Memory MB | Copies | MB copied | v7 ms | Port ms | CPU |
|---|---|---|---|---|---|---|---|
| `2000_6` | 7, 2 runs | 49.3 | 2,319,463 | 208 | 74.3 | 74.8 | +0.7 % |
| `200_40` | 7, 2 runs | 5.6 | 1,672,456 | 108 | 51.7 | 52.3 | +1.1 % |
| `synth_med` | 21, 4 runs (fastest rep) | 18.6 | 10,993 | 91 | 10.9 | 11.0 | +1.0 % |
| `synth_mix` | 21, 6 runs (median) | 11.4 | 15,627 | 53 | 6.72 | 6.77 | +0.7 % |
| `synth_grow` | 21, 4 runs (fastest rep) | 70.8 | 18,387 | 367 | 25.6 | 26.1 | +1.8 % |

The small traces (7 to 26 ms) vary by up to 10 % between runs of 7 reps, so they were run again with 21 reps. The first v7 run of each 21-rep batch is left out: it was the first run in the process and was 15 to 30 % slower. The replay has no JS blocks (op 8 is not in the traces), so it does not measure the walk of the JS pages in `sumTask`.

Open points of 6e:

| Point | Detail | Where to settle |
|---|---|---|
| Owner check in realloc | Settled in 12b (2026-10-16): a realloc of a block of another task (a stale pointer) counts in `dealloc_miss` and makes a clean trap, before any change. Test `bench/rowner.mjs`. | Done |
| Leak counter | `handle` calls `taskEnd`, which frees all blocks of the task. So "live bytes 0" also passes when a task leaks. A check build that adds the bytes that `taskEnd` frees to `LIVE_BYTES` gives 0 today. A counter of these bytes shows a leak. | 4g and 4h (M11, H3) |
| `wild.mjs` on the production host | Done in 12a: `bench/wild.mjs`, test exports `set_wild`, `fault_next_wait(4)` and `(5)` | Done |

### Status of step 6a, 6d (2026-10-16)

| Step | State | Where |
|---|---|---|
| 6d | Done | `hostlib/alloc.zig` (`roc_alloc`, `roc_realloc`: `mem.trapClean()` on 0; `FAIL_NEXT` in `allocIn`), `host/host.zig` (test export `fail_next_alloc`, with `set_copy` and the other bench exports), `platform/main.roc` (export list) |
| 6a | Done | `hostlib/alloc.zig` (`hostAllocFor`, `hostReallocFor`, `allocHostOrTrap`, `reallocHostOrTrap`), `hostlib/roc.zig` (`logPushCopy`, `log_clear`), `hostlib/wordbuf.zig` (`push`, `pushCopy`), `host/host.zig` (`handleImpl`), `bench/core.js` (`drainLog`), `bench/app.roc` (request option `dbg`), `platform/main.roc` (exports `log_ptr`, `log_len`, `log_clear`) |

`fail_next_alloc` is a test export: the next call of `allocIn` gives 0 (`roc_alloc`, `roc_realloc` that moves a block, `js_alloc`, the allocations of the host). Step 7a moves it to the bench list.

Tests (nightly 10-12, Node 26.7):

| Test | Command | Result |
|---|---|---|
| 6a: 400 requests in 4 rounds of 100 (200 with `dbg`, 200 good), variants b and a | `node bench/log-test.mjs bench/out/app.wasm` | PASS: 0 bad bodies, 200 of 200 `dbg` requests trap clean, 200 x 200 log lines read, live bytes 0, `dealloc_miss` 0, log empty, no retired instance |
| 6d: `fail_next_alloc` before the next `roc_alloc` of a waiting task | `node bench/oom-test.mjs bench/out/app.wasm` | PASS: the two victims trap (one for the Roc path, one for the JS path), clean, the other 58 requests correct, live bytes 0 |
| 6d: `roc_alloc` and `roc_realloc` on the allocator driver | `bench/alloc-test.sh` (`bench/oomclean.mjs`) | PASS: both trap, clean for owner 7 |
| Old tests | `bench/build.sh`, `node-test.mjs`, `overflow-test.mjs --expect-shared`, `strloop-test.mjs`, `bench/alloc-test.sh` | PASS |

The test uses rounds of 100 because the host has 254 task slots: more tasks at once made `taskOf` trap. Since 2c, JS gives a 503 (a shed) above 254.

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 6a: `allocHostOrTrap` and `reallocHostOrTrap` use `OWNER` (the old owner) | `log-test.mjs` | FAIL: `dealloc_miss` 40,400 (`log_clear` frees blocks that `task_abort` already freed) |
| 6a: no `drainLog` in `core.js` | `log-test.mjs` | FAIL: no log lines, live bytes 1,804,288 |
| 6d: `roc_alloc` does not trap on 0 | `oom-test.mjs` | FAIL: the victim writes through address 0 and returns a bad body, no trap |
| 6d: `roc_alloc` does not trap on 0 | `oomclean.mjs` | FAIL: returns, not clean |
| 6d: `roc_realloc` does not trap on 0 | `oomclean.mjs` | FAIL: returns, not clean |

Choices for 6a and 6d:

| Question | Answer |
|---|---|
| `OWNER = 0` around the calls (the plan) | Not done. The functions take the owner: `hostAllocFor(0, ...)`. `OWNER` is never changed, so an out-of-memory trap in these calls leaves `OWNER` as the task that runs. With a window, the trap would leave `OWNER` 0, `task_abort` would call `freeOwner(0)`, and the task would leak. Same effect on the blocks. |
| `handleImpl` (response block) | Uses `allocHostOrTrap` for the same reason (it had the window). |
| `log_clear` | Frees the entries and the buffer, and resets `LOG`. Needed for "live bytes 0" (H2 says the same). |
| Where JS reads the log | `drainLog` in `bench/core.js`: after each `handle` and after each `task_abort` that is clean (the heap is trusted). Variant a has no `task_abort`: it reads the log after a trap too, in a try/catch. `opts.onLog(level, text)` gets each line. |
| `dbg` request option | `bench/app.roc`: `<id> <trap> <depth> <items> dbg` writes 200 lines after its waits, then crashes. 200 lines are 600 words: the `LOG` buffer grows once (512 words at first). |
| `bench/build.sh` and `research/alloc/build.sh` | `roc build` exits 2 for warnings (the `dbg` in an optimized build). Both scripts accept exit 2 and still fail on exit 1. |
| Export list | `log_ptr`, `log_len` and `log_clear` were not in the list of `platform/main.roc`: added with `fail_next_alloc`. |

## 7. ABI and build settings

| Risk | Where | Now |
|---|---|---|
| R1 | `platform/main.roc:12` | The exports list has bench and test functions: `set_copy`, `copy_bench`, `alloc_bench`, `heap_fill`, `walk_bench`, `stats_reset`. `set_copy(0)` on a shared instance made 24 of 64 requests trap (`bench/README.md:182`). |
| R3 | `platform/main.roc` | Done in 7b: the stack size and the memory are in the header. `hostlib/canary.zig` reads the layout from the linker. |
| R4 | `host/roc_platform_abi.zig` | The generated glue (975 lines) is committed. 7c: `bench/ci-layout.sh` fails when a nightly gives other glue. |

| Step | Change | Test |
|---|---|---|
| 7a | Two export lists: production (`init`, `handle`, `task_abort`, `task_cancel` (3c), `task_slots` (2c), `js_alloc`, `res_free`, `stack_first`, `set_free_mark` (6e), `check_heap` (12d), the log exports, the counter exports (M11, H3), the CPU globals of 5a and `trap_cause` (5b)) and bench (all others, also the test export `fault_next_wait` (4-pre)). One way: a second platform file `bench/platform/main.roc` that adds the bench exports, and a build option that leaves the bench functions out of the production host. | Read the export section of a production build: no bench export. The bench tests still pass on the bench build. |
| 7b | Put the stack size and the memory settings in the `targets.wasm32` record of the platform header (`initial_stack_size`, `minimum_memory`, `maximum_memory`; read in `roc:src/compile/targets_config.zig:67-74`). `hostlib/canary.zig` gets `STACK_SIZE` from the same build value. Remove the flags from `bench/build.sh`. | Build with a plain `roc build --target=wasm32`. `check-layout.mjs` gives STACK-FIRST with a 1 MB stack. Remove the header field: the stack size changes. |
| 7c | `bench/ci-layout.sh` makes the glue again and fails on a diff with the committed file. | Change one line in the committed glue: CI fails. |

### Status of step 7 (2026-10-16, 7b and 7c; 7a is open)

| Step | State | Where |
|---|---|---|
| 7b | Done | `platform/main.roc` (`initial_stack_size: 1048576`, `minimum_memory: 0`), `hostlib/canary.zig` (no `STACK_SIZE`), `bench/build.sh` (no flags), `bench/check-layout.mjs` (`--header`), `bench/mem-limits.mjs` |
| 7c | Done | `bench/ci-layout.sh` (glue check before `bench/build.sh`) |

Choices for 7b:

| Question | Answer |
|---|---|
| Field names and units | `initial_stack_size`, `minimum_memory`, `maximum_memory`: integer literals in bytes (`roc:src/compile/targets_config.zig:584-606`). `roc:src/cli/main.zig:9742-9756` passes them to the linker as `-z stack-size=N` and `--initial-memory=N`. The pinned nightly 10-12 and the nightly 10-09 both read them (checked below). |
| `minimum_memory: 0` | The same as the old `--wasm-memory=0`. The linker sizes memory from the data and the stack: 21 pages, the same file as with no field. The field stays so that a nightly with another default does not change the memory. |
| `maximum_memory` | Not set. M5: the platform header sets no maximum, because the app developer cannot change it. The module has no maximum (`bench/mem-limits.mjs`: initial 21 pages, maximum none), as before. |
| `STACK_SIZE` in `canary.zig` | Removed. Stack first: the floor is 0 and the size is not needed. Data first: the floor is the linker symbol `__data_end` (the stack starts there). One source of truth with no build option, no second file and no generated constant. It is the real layout, not a copy of the request. |
| `research/alloc/build.sh` | Not changed. It builds a harness copy with its own header, so its flags stay. |
| `bench/check-layout.mjs --header platform/main.roc` | A stack-first build must have a stack size (the start of `__stack_pointer`) equal to `initial_stack_size` in the header. A missing field is a failure too. `bench/build.sh` and `bench/ci-layout.sh` pass it. |

Tests (nightly 10-12 unless noted):

| Test | Result |
|---|---|
| Plain `roc build --opt=speed --target=wasm32 bench/app.roc`, `check-layout.mjs` | STACK-FIRST, stack pointer 1,048,576 (1 MB), data from 1,048,585. Memory: initial 21 pages, no maximum. Same file as `minimum_memory` left out. |
| `bench/build.sh` with no stack or memory flags | The 3 apps are STACK-FIRST, stack 1 MB |
| `node bench/node-test.mjs bench/out/app.wasm` | PASS (exit 0) |
| `node bench/overflow-test.mjs bench/out/app_deep.wasm --expect-shared` | PASS |
| Nightly 10-09, header 1 MB, `stack_floor` export added for the test | Data first, stack pointer 1,313,904, floor 273,520 = `__data_end` 265,328 + 8,192 margin. The same as the old `top - 1 MB`. |
| Nightly 10-09, header 512 KB | Stack pointer 789,616 (= 265,328 + 524,288). Floor 273,520: it follows the header. |
| `bench/ci-layout.sh nightly-2026-10-12-2664a27` (with `ROC` set) | PASS |

Revert checks:

| Revert | Result |
|---|---|
| Remove `initial_stack_size` from the header, plain build | The stack pointer is 8,388,608 (8 MB, the roc default). `check-layout.mjs` alone still says STACK-FIRST, but `--header` gives STACK-SIZE, exit 1. `overflow-test.mjs --expect-shared` on that build: FAIL (depth 7000 alloc: a V8 RangeError retired the instance, not a canary trap; the 1 MB stack no longer limits the depth). |
| Old `canary.zig` (`STACK_SIZE` = 1 MB) with header 512 KB, nightly 10-09 | Floor 8,192: wrong (the stack floor is 273,520). The new code gives 273,520. |

Choices and checks for 7c:

| Item | Detail |
|---|---|
| Order | `bench/ci-layout.sh` makes the glue into `.cache/ci/<tag>/glue` and runs `diff -u` with `host/roc_platform_abi.zig` first. Only then does it run `bench/build.sh`, which copies the new glue over the committed file. |
| `ROC` | `bench/ci-layout.sh` uses `ROC` when it is set, else `bench/get-roc.sh <tag>`. |
| Test: change one line of the committed glue | FAIL, exit 1, the diff is printed, and the committed file is not overwritten. |
| Restore the line | PASS |

## 8. Platform API

The API is `API.md` (2026-10-15). It replaces draft 1 of this section: kind numbers, a `Worker` record and a scripted record for `roc test`. The scripted record cannot work: an `expect` cannot run a function with `!` (`../research/core-shape/`, API.md RF9).

| Gap | Design says (`API.md`) | Code has |
|---|---|---|
| G1 | One entry `event! : Event => Outcome` for all Workers handler kinds (API.md 10) | `requires { handle! : Str => Str }` (`platform/main.roc:2`). No method, headers or status. The body must be UTF-8. |
| G2 | Typed modules over programs of ops (API.md 6, 7). The app never sees a kind number. | The app imports `pf.Wait` and uses raw kind numbers (`bench/app.roc:10,14`) |
| G3 | Effect errors are results: JS errors come back with name and message (API.md 4) | Status 0 on any error. JS drops the message (`bench/core.js:16-20`). |
| G4 | `Scheduled`, `Queue` and the other events (API.md 10) | Only the fetch handler |

| Step | Change | Test |
|---|---|---|
| 8a | The bridge (API.md 4 to 6): hosted `await!`, `call!` and `native!`, the wasm imports and statuses 4 and 5 of API.md 4.1. `Js`, programs and `Io` in Roc (`platform/Js.roc`, `platform/Io.roc`), the encoder and decoder of the CBOR profile (API.md 5) in the Zig host with the glue types (API.md 5.1) and in the shim (from `research/api-probe/cbor/cbor.mjs`), `Packed` values and `pf.pack` (API.md 5.2), the ref table with one id for each object (RS1), the program interpreter (all ops of API.md 6.2, with `Race` and the `null` rule OP7), the platform helpers (`pf`, API.md 6.4), the ref table and the pin table in JS (from `research/api-probe/`). Remove `Wait.wait!`: this also removes B2 and B3 (6b, 6c). | HD1 to HD7 of API.md 5.1 (glue checks, glue diff, round trip, the Roc decoder as an oracle, fuzz, leaks, RFC 8949 vectors). Same bytes in Zig and JS for a set of fixtures. A `Packed` value of 200 rows reaches Roc as one `List(U8)` and `Cbor.parse` reads it. Two refs of one JS object in a task are equal. Revert (a new id for each ref): they are not. A program of 4 ops gives the value of the last op with one wait. A promise in `call!` gives status 2. `Io.both!` of two operations that each wait 100 ms takes one wait and about 100 ms. Revert (`Par` runs the branches one after the other): about 200 ms. A `js_alloc` that fails during a wait gives a clean OOM trap (status 4). After 10,000 tasks with traps and cancels, the ref table is empty (10c). Revert (no ref free at a trap): it is not empty. A pinned `CryptoKey` is used by a later task. `Get` and `Fields` on `null` and on `undefined` give `Undefined`, and `Call` on `null` gives status 1 (OP7). Revert (no `?.`): `Get` on `null` gives status 1. `Io.race!` of two operations that wait 50 ms and 500 ms gives index 0 after about 50 ms and one wait, and the other branch sees its abort (OP8). Revert (`Race` as `Par`): about 500 ms. A `Race` with no branch is status 3. `Io.both!` of two `Io.sync` values gives `Ok`. Revert (`call!` when each branch is sync): status 2. `pf.packEach` gives each item with its field as `Packed`, and `pf.findById` gives the item of the id, and `undefined` for an unknown id (API.md 6.4). Revert (`findById` gives the first item): the test fails. |
| 8b | Events (API.md 10): `requires { event! : Event => Outcome }` with the full `Event` type, `provides` `roc_event`. `makeHandler` gives a subclass of `WorkerEntrypoint` with `fetch` and `scheduled` methods (MODULES.md 3), and `Other` for the handler names in its `other` option. `Worker.Scheduled` with `no_retry!`, and the cron rules of MODULES.md 3 (the shim never calls `noRetry` by itself). `Request`, `Response` and `Body` (MODULES.md 4), with `Body.writer!`, `compress!` and `decompress!`. `Ctx.respond!` with its rules (10.2), and `Ctx.pass_through!` (MODULES.md 11). The `Worker` wrapper with typed handlers (MODULES.md 3). The event `Manifest`, `objectClass` and `entrypointClass` are phase B (8f): objects and RPC are phase B (API.md 7). | Binary body (0x00 to 0xFF) round trip, 100 headers, status 404. `GET /cdn-cgi/local/scheduled?cron=*/5+*+*+*+*&time=1700000000000&format=json` in Miniflare reaches `scheduled!` with the cron `*/5 * * * *` and `time_ms` 1700000000000, and answers the outcome `ok`. Revert (`time_ms` from `Date.now()`): the time differs. A `scheduled!` that gives `Err` answers an outcome that is not `ok` (status 500) and `noRetry: false`. The same handler that calls `no_retry!` before `Err` answers `noRetry: true`. Revert (the shim calls `noRetry` on each `Err`): the first one answers `noRetry: true`. A Worker with no `scheduled!` answers an outcome that is not `ok` and `noRetry: false`. In a Node test of `js/`, the default export of `makeHandler` is a subclass of `WorkerEntrypoint`. A `queue` call in `other` reaches `Other`. `Unhandled` gives a 500 and a log line. A handler that gives `Err` gives `Failed`: a 500 and a log line with the error. Work after `respond!` runs after the response. A second `respond!` gives status 1. A task that runs past 30 s after `respond!` is cancelled. Revert to `Str`: the binary test fails. After `Ctx.pass_through!`, a handler that gives `Err` makes the `fetch` handler throw. Revert (always a 500): the `fetch` handler gives a 500. `pass_through!` in a `Scheduled` event gives `InvalidState`. An `other!` handler that gives `Ok(v)` gives `Reply`, and the JS caller gets `v`. In workerd, a read of the request body after `respond!` gives `BodyErr` (API.md 10.2). A `Body.writer!` response: the client gets the first chunk before the task writes the second. Revert (the shim reads the stream to its end before it responds): the client gets all chunks at once. `compress!` with `Gzip` and `Deflate` gives bytes that Node `zlib` decodes to the input, and `decompress!` of them gives the input. Revert (`decompress!` with the wrong format name): the test fails. |
| 8c | Phase A modules (API.md 7, with the signatures and conventions MC1 to MC13 of MODULES.md): `Http`, `Body`, `Env`, `Secret`, `Ctx`, `D1`, `Sql`, `R2`, `Cache`, `WebCrypto`, `Time`, `Log`, `Js`, `RateLimit`, and the wrapper `Memo`. The `Cbor` format (API.md 5.2): a generic package in its own repository (`roc-cbor`), from `research/api-probe/cbor/Cbor.roc` with its `expect`s. Start from `research/api-probe/modules-check/`. The `conformance/` app: one route for each function and its `Io` twin, run in Miniflare (local D1 and R2). | Each route passes. Revert (a wrong JS method name in one function): its route fails. `D1` with an `Int` above 2^53 stores the exact value. Revert (send a BigInt): `D1_TYPE_ERROR`. `D1.batch!` is one crossing. `D1.all!` gives rows of the type of the call, and `first!` gives `NotFound` for no row. `D1.all!` of a query with 3 rows gives 3 rows. Revert (no `Get "results"`, API.md 6.2): `BadData`. `R2.get!`, `R2.head!` and `Cache.get!` of a missing key give `NotFound`. Revert (no OP7: `Get` on `null` throws): they give `R2Err` and `CacheErr`. `Time.sleep!(100)` takes one wait and about 100 ms. `D1.batch!` of 2 inserts and a select gives 3 `D1.Result`s, and `first()` of the third reads the count. A `U64` of 2^60 in an RPC argument and in a `Memo` value comes back exact. `R2.put_with!` with a wrong `etag_matches` gives `PreconditionFailed`, and `R2.absent` on a key that exists gives `PreconditionFailed` locally and on the edge (the wildcard is in the workerd source only). `only_if` with a right `etag_matches` and an `uploaded_before_ms` in the past gives `PreconditionFailed`. Revert (the module sends only the first field): `Ok`. R2 multipart (MODULES.md 5.3): request 1 runs `create_multipart_upload!` and `upload_part!(1, 5 MiB)` and gives the `R2.Upload` and the `Part` as JSON. Request 2 runs `upload_part!(2, 1 KB)` on that data, and request 3 runs `complete!` with both parts: `get!` gives 5 MiB + 1 KB with the right bytes. Revert (each function of `Upload` calls `createMultipartUpload` in place of `resumeMultipartUpload`): `complete!` gives `R2Err`. `put_with!` of a `Body.writer!` stream gives `R2Err` with "known length", and with `length_bytes` it stores the bytes. Revert (no `FixedLengthStream`): `R2Err` with `length_bytes` too. `put_with!` with `http: { cache_control: "max-age=60" }`: `head!` gives it, `list!` gives an empty `http`, and `list!` with `include: [Http]` gives it. Revert (`include` not sent): an empty `http`. Keys `a`, `b`, `c`: `list!` with `start_after: "b"` gives `c` locally and on the edge (in the workerd source only). Revert (not sent): `a`, `b`, `c`. `get_with!` with `range: From({ offset_bytes: 2, length_bytes: 3 })` gives 3 bytes, and `obj.?range` is the same range. Revert (the module does not read `range`): `Err`. `put_with!` with a wrong `Sha256` checksum gives `R2Err`, and with the right one `meta.checksums` has it. A put with no checksum has an MD5. `D1.all!` of rows above 1 MiB gives `TooLarge`, and `all_with!` with `max_bytes` of 2 MiB gives the rows. Revert (no limit in `pf.pack`): `all!` gives the rows. `D1.with_session!(Primary)`: `bookmark!` before a query gives `NotFound`, after an insert `Ok`, and a session `After(bookmark)` reads the row. Revert (`getBookmark` of null read as text): `Ok("")`. `WebCrypto` (MODULES.md 10): `generate_key!` of `Ecdh(P256)` and of `X25519` for two sides, then `derive_bits!` on each side gives the same bytes. `generate_key!(Ed25519)`: a signature of the private key verifies with the public key. `RsaOaep` and `AesGcm` encrypt and decrypt round trip. `export_key!` of an `import_key!` of `Raw(b)` gives `Raw(b)`. Revert (`decrypt!` with `call!` in place of `await!`): status 2. `timing_safe_equal!`, `random!` and `random_uuid!` run in `call!`. `Cache.put!` of a 206 response gives `CacheErr`, and `delete!` of a key that is not cached gives `NotFound`. A request in Miniflare has a `Request.Cf` with `colo` `Ok`, and a field that Miniflare does not set gives `Err(Missing)`. Revert (the module reads null as an empty text): `Ok("")`. A pure test (`roc test`) of the conversion of MC10: 1 ms gives 1 s, 1,000 ms gives 1 s, 1,001 ms gives 2 s. Revert (round down): 1,001 ms gives 1 s. `WebCrypto.verify!` with a JWK is one crossing. `Memo`: a second request gets the value with no `load!`. A `Secret` in `Log` fields, and in a CBOR encode, does not compile. |
| 8d | Errors: each phase A module maps `Error(name, message)` to its own tags (MODULES.md MC9, table "Named error tags") | A fetch to a closed port gives `Network(Thrown)`, locally and on the edge (a host that does not answer). A fetch to a host that does not exist gives `Network(Thrown)` too. A fetch of `"not a url"` gives `HttpErr` with `TypeError`. A D1 `UNIQUE` failure gives `Constraint` with "UNIQUE constraint failed", locally and on the edge. Each test writes the JS `name` and `message` that it got to `bench/README.md`, because the docs do not give them. Revert (no map): `D1Err` and `HttpErr` for all. Revert (`Http` maps by the message "Network connection lost" only): the DNS failure of a host that does not exist gives `HttpErr`. |
| 8e | `Native` (API.md 8): `zstd_decode` with an output limit, the zstd stream ops, and BLAKE3 and SHA-256 with state | Decode a package `.tar.zst`: the bytes match `zstd -d`. A small archive that decodes to more than the limit stops at the limit. Revert (no limit): memory grows past it. BLAKE3 of a file in chunks of 64 KB equals `b3sum`. A handle of another task gives status 1. |
| 8f | Phase B modules and events (API.md 7, 10; MODULES.md 5 to 13). The event `Manifest` at load, `objectClass` and `entrypointClass` in `js/`, and the method names from the manifest (API.md AQ10, moved from 8b). The manifest also gives the `default` RPC methods and the `handlers` of each class: a JS method only for a handler that the class has (MODULES.md 3). Durable Objects (MODULES.md 7): SQLite-backed classes only, `init!` in `blockConcurrencyWhile`, `alarm!` with `retry_count` and `is_retry`, the alarm calls with `await!` and `Io` twins, `list!`, `delete_all!`, `Object.SqlInfo`, `id!`, `jurisdiction`, the `_with` forms with `location_hint`. RPC (MODULES.md 8): `Rpc.entrypoint` with `fetch!`, the event `EntrypointFetch`, the RPC limits. `Ctx.respond!` in the `Fetch` of a Durable Object (API.md 10.2). The entry points of `queue`, `email` and `tail` go in a major release (API.md 10.1). `Worker.TraceItem` of the `tail` entry (MODULES.md 3). | One conformance route or event for each. Revert as in 8c. A `Queue(a)` constant sends a message that `each!` reads as the same type. A body that is not an `a` is retried, not acked. An `Rpc` constant calls an object method and a service method, and an unknown method throws. A WebSocket stays open more than 30 s after its 101 response. A Worker gives an upgrade request to a Durable Object with `fetch!`, and the client gets the 101 response of the object. Two clients in one room: a message of one reaches the other and not the sender. Revert (no `==` on sockets): the sender gets it too. The object leaves memory (hibernation), and the next message reads the attachment of its socket. An auto response answers `ping` with no event. `connect!` to a WebSocket echo server sends and receives one message. A request with no `Upgrade` gets 426 from the Worker and `NotUpgrade` from `accept!`. A class in Roc with no export, and an export with no class in Roc, each stop the load with the name of the class. Revert (no check): the load passes, and the first call fails. An RPC method that is only in the manifest is on the prototype. A class with `alarm!` has an `alarm` method on its prototype, and a class with no `alarm!` has none: there, `set_alarm!` in a `fetch!` gives `StorageErr`. Revert (the shim always defines `alarm`): `set_alarm!` gives `Ok`, and the alarm runs 7 times (one log line each). An `init!` that waits 100 ms (`Time.sleep`), then creates a table: two `fetch!` calls sent at the same time to a new object both read the table. Revert (`Init` runs with no `blockConcurrencyWhile`): one of them fails with "no such table". An `init!` that gives `Err` while the local KV key `fail-init` exists: a `fetch!` to the object gets `ObjectErr`. The test deletes the key, and the next `fetch!` passes (a new constructor runs `init!` again). Revert (the shim does not throw on `Err` of `init!`): the first `fetch!` passes. An `init!` that waits longer than the `Init` deadline (API.md 10.2, made smaller for the test) is cancelled, and the `fetch!` gets `ObjectErr` with the name of the task. Revert (no `Init` deadline): the `fetch!` waits until Workers resets the object. An `alarm!` that gives `Err` while `retry_count` is less than 2 runs 3 times and logs `retry_count` and `is_retry`: 0 and false, 1 and true, 2 and true. Revert (the shim always gives `retry_count` 0): it runs 7 times. `get_alarm!` after `set_alarm!(t)` gives `t`. Revert (`call!` in place of `await!`): status 2. With a compatibility date before 2026-02-24: a table, a cell and an alarm, then `delete_all!`: the table is gone, the cell gives `NotFound` and `get_alarm!` gives `NotFound`. Revert (no `deleteAlarm` in the program): `get_alarm!` gives the time. Cells `a1`, `a2` and `b1`: `list_with!(self, { prefix: "a" })` gives `["a1", "a2"]`. Revert (the prefix is not sent): `b1` too. A class in a `new_classes` migration (KV-backed): its first event fails with a message that names the class and `new_sqlite_classes`. Revert (no check in the constructor): the message has no class name. `sql_run!` of an insert of 2 rows into a table with no index gives `rows_written` 2. Revert (the module reads `changes` as for D1): `BadData` or 0. A Tail Worker that gets the trace of a fetch that logs `console.log("a", 1)` and throws: `outcome` is `exception`, `event` has the method and url, the log `message` is `["a",1]`, and `exceptions` has one item. Revert (`event` read for each kind, not only fetch): a scheduled trace gives `BadData`. A trace with 2 MiB of logs: the handler gets the item with fewer logs, and the Tail Worker logs one warning. Revert (no limit): the handler gets all logs. `sql!` of 2 MiB of rows gives `TooLarge`, and `sql_with!` with `max_bytes` of 4 MiB gives the rows. Revert (no `pf.pack` limit for object SQL): `sql!` gives the rows. `counters.named("x").id!()` equals `self.id` in the object. Revert (an id made in Roc from the name): they differ. `counters.jurisdiction(Eu).named("x").id!()` in Miniflare gives `ObjectErr` with "Jurisdiction restrictions are not implemented in workerd." Revert (the jurisdiction is not sent): it gives an id. A service binding RPC call to an `rpc` method of the default export gives the reply. Revert (`makeHandler` gives a plain object): the call throws. `Service.fetch!` on a binding with `entrypoint = "Admin"` reaches the `fetch!` of `Rpc.entrypoint("Admin", ...)`, and not the `fetch!` of the Worker. Revert (the shim sends `Fetch` with no name): the `fetch!` of the Worker answers. A callee that gives `Err(Nope(3))`: the caller gets `RpcErr` with the message `Nope(3)`. Revert (the shim throws a fixed text): the message is not `Nope(3)`. The `Fetch` of an object calls `respond!`, then writes a cell: the Worker gets the response before the write, and a later read of the cell gives the value. Revert (`respond!` gives `InvalidState` in an object): the test fails. `connect!` to a server that answers 200 gives `NotUpgrade` (OP7). `Io.race!` of `receive` and `Time.sleep(50)`, with the message sent at 100 ms: the sleep wins, and the next `receive!` gets the message. Revert (the lost branch takes the message): the next `receive!` does not get it. `Message.ack!` of the second message of a batch acks only it (`pf.findById`). `Queue` (MODULES.md 6): `each!` gives `msg.attempts` 1, then 2 after an `Err`. Revert (the module gives the handler a fixed `Message`): 1 both times. `send_batch_with!` of 3 messages with `delay_ms: 1_000` and `retry_all_with!(batch, { delay_ms: 1_000 })`: all 3 come again with `attempts` 2. Revert (the delay option is not sent): Miniflare gets no `delaySeconds` (the shim logs the options). `send_batch!` of 101 messages gives `QueueErr`. `Kv` (MODULES.md 5.2): `get!` of a 2 MiB value gives `TooLarge`, and `get_with!` with `max_bytes` of 4 MiB gives it. Revert (no `pf.readUpTo`): `get!` gives the value. `put_with!` with `metadata: { owner: "a" }`: `get_with_metadata!` gives it typed, `(key.metadata ? |_| Missing).parse()?` of `list!` gives it, and a key with no metadata gives `Err(Missing)` in the field. Revert (metadata not sent): `Err(Missing)`. Typed bytes (MODULES.md MC5): an RPC argument `{ data : Cbor.Bytes, list : List(U8) }` to a JS callee: `data` is a `Uint8Array` and `list` an `Array`. A `Queue.v8` message with a `Cbor.Bytes` field reaches a JS consumer with a `Uint8Array`. Revert (`Cbor.Bytes` with the derived `encoder_for`): `data` is an `Array`. Object SQL: an insert that breaks a `UNIQUE` index gives `Constraint`. Revert (no map): `SqlErr`. `Email.Mail.forward_with!` with an `X-Test` header: the forwarded mail has it (Miniflare). |
| 8g | Measure: one crossing with programs of 1, 4 and 16 ops, the decode of 200 D1 rows, `D1.all!` (CBOR, typed) against `D1.rows!` (`Js`, no types) for 20 and 200 rows, and `Crypto.SHA256.hash` (builtin, in wasm) against `crypto.subtle.digest` for 1 KB, 64 KB and 1 MB (the size where `digest` is faster, MODULES.md 10), in the platform (wasm), local and on the edge (AQ4, AQ5) | None: a measurement. Numbers in `bench/README.md`. |

## 9. JS shim

| Gap | Now |
|---|---|
| G5 | The shim is `bench/core.js`, mixed with test code (`expected`, `check`). `bench/worker.js:12-15,33` makes `io` from the `env` of the first request. `io` has no `ctx.waitUntil`, no `request.signal` and no request headers. |

| Step | Change | Test |
|---|---|---|
| 9a | Move the runtime to `js/` (one entry module, for example `js/index.js` that exports `makeHandler(module, opts)`). It returns the handlers of API.md 10.1 for the Worker. `objectClass(name)` and `entrypointClass(name)` give the classes, and the methods come from the event `Manifest` (API.md AQ10). Test helpers stay in `bench/`. | `bench/worker.js` and the Node tests use `js/` and still pass |
| 9b | The `io` call gets the task id. The task table (2c) keeps the context of each task: `env`, `ctx`, the `event` object, and its ref table. These are the roots of API.md 6.2 (OP3). | Two requests at the same time with different headers. Each effect sees the headers of its own request. Revert to one shared context: the test fails. |
| 9c | `Ctx.wait_until!` and `Ctx.respond!` (API.md 10.2). The task table keeps the context of a task (its ref table and its roots) after the task ends, until each program of `Io.start!` settles, or until the 30 s `waitUntil` limit (API.md RS1, 6.5). | A `waitUntil` promise runs after the response. Revert (no `waitUntil`): the promise stops with the response. A started program that awaits 100 ms and then reads a `Stream` body and does a `Cache.named` put, after its task returned: the put is done, and then the ref table of the task is empty. Revert (free the context at the task end): status 1 and a log line, and the put is not done. A started program that throws gives one log line. A started program that gives a Roc-level `Err` (`R2.put_with!` with a wrong `etag_matches`) gives no log line, as MODULES.md 11 says. |

## 10. Body handles

| Risk | Now |
|---|---|
| R2 | All bodies go through wasm memory, and wasm memory never gets smaller. A 10 MB R2 object uses 10 MB of the 128 MB isolate limit for the life of the instance (and counts in the memory budget of problem 4). |

| Step | Change | Test |
|---|---|---|
| 10a | JS keeps large bodies (`ReadableStream`, `Response`) as refs (API.md 9, RS3): a body is `Stream(Ref)`. `Response` can give it back to JS with no copy into wasm. Done in 8c. | Node: send an R2 object of 50 MB through `R2.get!` to the response. wasm memory grows by less than 1 MB. |
| 10b | `Body.bytes_with!(body, { max_bytes })` and `Body.chunk!` copy the bytes into wasm only when Roc needs them. Ingest needs only `main.roc` from the archive. Done in 8c. | Read the first 1 KB of a 50 MB body: wasm memory grows by less than 1 MB. Revert (copy all): it grows by 50 MB. |
| 10c | The task table frees the refs of a task (body ids too) at its end, its trap and its cancel (3c, API.md RS1). At the end of a task with programs of `Io.start!` that still run, it frees them when the last one settles, or at the 30 s `waitUntil` limit (9c). Done in 8a and 9c. | The ref-table test of 8a, and the started-program test of 9c |

## 11. Release

| Gap | Now |
|---|---|
| G6 | `platform/targets/` is in `.gitignore`. There is no release workflow, so a user cannot use the platform by URL. |

| Step | Change | Test |
|---|---|---|
| 11a | A release workflow: build the production host (7a) with the pinned nightly (`compat/last-stack-first-nightly`), bundle the platform with `roc bundle`, and attach the bundle and the `js/` package to a GitHub Release | Run on a test tag. A new app builds with the release URL. |
| 11b | Publish `js/` (npm, or a file in the release that the app copies) | A new Worker project uses it with wrangler |
| 11c | An example Worker app with a wrangler config (with the compatibility flag `enable_request_signal`, for 3b), deployed by CI. 5d (CPU limit on the edge) runs on it. Also check what the edge does at 128 MB: is only the isolate stopped, and do the requests in flight fail? Also check the facts of API.md 10.2 on the edge: does `request.signal` fire when the client goes away after the response body is complete, and does a `Body.writer!` stream keep the request past 30 s while the task writes? The cron edge test of API.md AQ12: two cron triggers (`*/2 * * * *` and `1-59/2 * * * *`). The `scheduled!` handler writes a row (`cron`, `time_ms`, the time of the run) to D1 for each run, then gives `Err`. For the second cron it calls `no_retry!` first. It runs for 1 hour. The jurisdiction of MODULES.md 7 on the edge (local workerd does not have it). | The deployed example answers. 5d and the 128 MB check give their results. The two facts of API.md 10.2 give their results, and API.md 10.2 is changed if they differ. AQ12: the rows show for each `time_ms` how many runs each cron got. More than one run for a `time_ms` of the first cron, and one for the second, shows that production retries and that `noRetry` stops it. Write the answer in MODULES.md 3 and settle AQ12. Revert (the handler gives `Ok`): one run for each `time_ms` of both crons. `counters.jurisdiction(Eu).named("x").id!()` differs from `counters.named("x").id!()`. Revert (the jurisdiction is not sent): they are equal. |

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
| Response block of a task that ended | The host, in `handle` | None: JS reads it and frees it at once after `handle` returns (12-pre) | |
| Roc code statics (`roc_tail_pending`, `roc_tail_args`) | The task that runs | None: never live across a wait (12-pre) | |

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
| 12a-stack | Test of the stack copy: 64 tasks at depths of 10 to 4,000 frames, with a canary word in each frame. They wait and resume in random order. | All canary words are correct at each resume. Revert (the copy misses 32 words at the low end, or restores half): a canary is wrong. Changed 2026-10-16: a copy of one word less does not fail, because the lowest word is alignment padding and the top word is a dead slot of `handle` (12a status). |
| 12b | Check at resume when other code ran since the wait (`RUN_EPOCH` goes up at each export call, sum mode 2). Default `resumeCheck: "always"`. Check the owner word and the length of the response block. | A test export writes one word into a waiting task's page, with no trap: that task gets a 503, the others are correct. Revert to `"afterAlarm"`: the task returns a wrong body with status 200. A test export changes the length of a response block during the wait: the task gets a 503. Revert (no block check): the task reads past the block. A `js_alloc` with no task run between: the resume checks. Revert (counter only on task runs): no check. |
| 12d | Global check (export `check_heap`). Units: each is in exactly one place (a free run, a task page list, a large block, the reserve, foreign). The bitmap matches the free runs. Boundary tags match. Each small page's free list has `slots - live` entries. Task lists link back. Constant data and constant foreign units match their sums from `init`. Host globals are in range. Fail: cancel all tasks, drop, new instance (M1). | A test export breaks one table entry of each kind: each is found, and the instance is replaced. Revert (no check): the next requests get blocks that overlap (`dfree.mjs`-style check). Time of the check at 50 MB of heap: target under 1 ms. |
| 12c | Alarm: the task gets a 503, `freeOwner` frees its pages and its host task slot (after an unclean trap, `task_abort` gives -1 and today leaves the slot in use, 2c), and JS calls the global check (12d) before the next `handle` or resume. This replaces the retire after an unclean trap in `bench/core.js`. Change the tests of problem 1 that look for a retire (see "Change after 12c"). | `wild.mjs`: 0 bad bodies, the instance count stays 1 while the global check passes. Revert (retire as now): a new instance per alarm. |
| 12e | The global check with no alarm: when idle, and every `heapCheckEvery` requests (see "Check of shared memory with no alarm"). Set the default of `heapCheckEvery` from the time of 12d. | A test export breaks one table entry with no trap, then requests continue: with `heapCheckEvery` 100, the instance is replaced within 100 requests. With only idle checks, it is replaced when the requests stop. Revert (no 12e): the instance is never replaced, and a later request gets a wrong body. CPU cost with the default N: at most 0.1 % (bench of 12f). |
| 12f | Full-app bench on an idle machine: sums off (sum mode 0, bench build only), `"afterAlarm"`, `"always"`, each with the 12e checks on. Write the costs in `bench/README.md`. | None: a measurement |
| 12g | When talon runs on the platform: record its allocator calls (`TRACE=1 research/alloc/build.sh`), replay them against v7 (`research/alloc/scripts/all.sh` with the talon traces), run 12f on talon, and set `heapCheckEvery` from its median request time. Measure H7 and H8 on talon. | None: a measurement |

### Status of steps 12a, 12a-stack, 12b (2026-10-16)

| Step | State | Where |
|---|---|---|
| 12a | Done. `waitBegin` sums the task (`sumTask`: task record, small pages, large blocks, adopted JS blocks) and the fixed fields of the `Wait` record (`sumWait`), after the stack copy. `Wait` is an `extern struct` (12-pre): low, top, copy pointer, copy length, `out`, owner, at, then the new fields epoch, alarm, sum (48 B). The sum covers low, top, copy pointer, copy length, owner, at and epoch (not `out`, `alarm`, `sum`). | `host/host.zig` (`Wait`, `sumWait`, `waitBegin`), `hostlib/alloc.zig` (`SUM_K` is `pub`) |
| 12a-stack | Done, with a gap: see the revert table | `bench/app_stack.roc`, `bench/stack-test.mjs`, `bench/build.sh` (builds `app_stack.wasm`) |
| 12b | Done. `mem.RUN_EPOCH` goes up in each export that is not a pure getter (`handle`, the resume in `waitEnd`, `js_alloc`, `res_free`, `log_clear`, `task_abort`, `task_cancel`, `set_free_mark`, the bench and test exports). Sum mode 2 checks at a resume when the epoch changed, mode 1 only after `set_suspect`. Each resume in mode 1 or 2 also checks the response block in `out` (`jsBlockOk`): 0, 0, or the start of a JS block with owner word 0 and room for the length. | `hostlib/mem.zig` (`RUN_EPOCH`, `enter`), `host/host.zig` (`resumeCheck`, `alarm`, `set_sum`, `set_suspect`), `hostlib/alloc.zig` (`jsBlockOk`), `bench/core.js` (`resumeCheck` option, `SUM_MODES`) |
| Alarm path | One host function `alarm(w, cause)`: it writes the cause into the `Wait` record and traps. `task_abort(id)` frees the task (`waitDrop`) and gives maxInt - cause (JS: -2 sum, -3 block; -1 stays the unclean trap). In JS, `runner.alarm(...)` is the one path for an unclean trap and a failed check: `set_suspect(1)` on the old instance, replace (M1), result `{ status: 503, alarm: 'sum' \| 'block' }` (an unclean trap keeps its old result). 12c changes `runner.alarm`. | `host/host.zig` (`alarm`, `abortFree`), `bench/core.js` (`runner.alarm`, `ALARM_OF`) |
| Owner check in realloc (6e open point) | Done. A realloc of a block of another task (not the task that runs, not the host, not JS) counts in `dealloc_miss` and makes a clean trap, before any change. | `hostlib/alloc.zig` (`hostReallocFor`) |
| Canary check at free (4-pre open point) | Done. `roc_dealloc` calls `canary.check()` first, as the alloc path. | `hostlib/alloc.zig` (`roc_dealloc`) |

New exports (all in `platform/main.roc`). For the lists of 7a:

| Export | Use | List of 7a |
|---|---|---|
| `set_sum(mode)` | JS sets the sum mode from `resumeCheck` before `init`. Mode 0 only for benches. | Production (mode 0: bench only) |
| `set_suspect(on)` | JS sets it at an alarm ("afterAlarm") | Production |
| `alarms()` | Counter of alarms at resume (M11, H3) | Production |
| `sum_checks()` | Counter of sum checks at resume | Bench |
| `poke_wait(id, kind, arg)` | Test: a wild write with no trap. 1: `Wait.low` += arg. 2: XOR into the first JS block that task `id` adopted. 3: `out[1]` += arg at the next resume of `id`, before the checks. 4: XOR into the word at address `id`. | Bench |
| `set_wild(seed, words)`, `fault_next_wait(4)`, `fault_next_wait(5)` | Test: the wild-write hook. 4: random words from the host global `WILD_BASE` to the memory end, then a trap (the research hook). 5: the same write, then the task waits and traps after its resume. | Bench |

Tests (nightly 10-12, Node 26.7):

| Step | Test | Result |
|---|---|---|
| 12a | `node bench/wild.mjs bench/out/app.wasm <words> 20000 0.005 20 always` (64 at once, the writer traps after its resume) | 16, 256, 4,096 words: 0 wrong bodies (92, 102, 96 alarms "sum"; 101 to 104 replaces) |
| 12a | `node bench/resume-test.mjs bench/out/app.wasm`, A: `poke_wait` kind 1 (-16 to `Wait.low`) while the task waits | PASS: 503, alarm "sum" |
| 12a | same, B: kind 2 (one byte of the fetch body, an adopted JS block kept across the second wait) | PASS: 503, alarm "sum" |
| 12a-stack | `node bench/stack-test.mjs bench/out/app_stack.wasm`: 5 rounds of 64 tasks, depths 10 to 4,000 (each round has a 10 and a 4,000), 3 waits each, io of 0 to 10 ms. The canary of each frame is a small string `<salt>:<n>`, which is in the frame (the shadow stack) and is read after the waits. | PASS: 320 tasks, `bad=0` each, live bytes 0, no replace. Largest copy 1,024,608 B (256 B per frame). |
| 12b | `resume-test.mjs`, C: one byte of the string `level-1-of-request-<id>` of a waiting task, with no trap. 7 other tasks wait too and resume first. | PASS: 503, alarm "sum". The 7 others give correct bodies. |
| 12b | same, D: kind 3 (+64 to the length of the response block of the second wait) | PASS: 503, alarm "block" |
| 12b | same, E: one task alone; between its first wait and its resume only `js_alloc` runs | PASS: 1 sum check at that resume |
| Owner check in realloc | `bench/alloc-test.sh` (new `bench/rowner.mjs`): task 8 reallocs a 24 B block of task 7 to 5,000 B, and a 9,000 B block to 100 B | PASS: both trap clean, `dealloc_miss` 0 to 1, live bytes, bytes and the sum of task 7 do not change |
| Canary check at free | `bench/overflow-test.mjs bench/out/app_deep.wasm --expect-shared`, new free mode (`app_deep.roc` `<depth> free`: one list made at the top, freed at depth 0, no other allocation). Fresh runner, depths 3,000 to 4,000 by 500, then by 2 up to the first trap. | PASS: 25 bodies, canary intact for each, first trap at depth 4,046 (`unreachable`, the canary check), clean, instance kept, live bytes 0, the next request correct, `dealloc_miss` 0 |
| All | The old tests (list in the task). `bench/oomclean.mjs` changed: see the choices. | PASS |

Revert checks (each test must fail):

| Revert | Test | Result |
|---|---|---|
| 12a: sums off (`resumeCheck: "off"`) | `wild.mjs` 16, 256, 4,096 words | FAIL: 3, 29, 56 wrong bodies |
| 12a: no `Wait` fields in `sumWait` | `resume-test.mjs` A | FAIL: an out-of-bounds trap that is not clean (wrong stack restore) |
| 12a: no JS blocks in `sumTask` (no `sumAdopted`) | `resume-test.mjs` B | FAIL: no 503, a wrong body |
| 12a-stack: the copy misses its top word (length - 4) | `stack-test.mjs` | Does not fail. See the note below. |
| 12a-stack: the copy misses its lowest word (copy from low + 4) | `stack-test.mjs` | Does not fail. See the note below. |
| 12a-stack: the copy misses its lowest 32 words, or the restore writes back only half of the copy | `stack-test.mjs` | FAIL: `bad=1` (32 words), about half of the canaries wrong (half) |
| 12b: `"afterAlarm"` | `resume-test.mjs bench/out/app.wasm afterAlarm`, C | FAIL: a wrong body with status 200 |
| 12b: no block check | `resume-test.mjs` D | FAIL: the task reads 64 B past the block, a wrong body with status 200 |
| 12b: the epoch goes up only at `handle` and at a resume | `resume-test.mjs` E | FAIL: 0 checks at the resume |
| Owner check in realloc removed | `rowner.mjs` | FAIL: no trap; small: task 7's block is freed (live bytes 32 to 8,192, its bytes and sum change); large: its sum changes (the requested end) |
| No canary check in `roc_dealloc` | `overflow-test.mjs` | FAIL: depth 4,046 free gives a body with a broken canary (the free ran below the canary limit) |

Note on "copy one word less": the test finds no error, because the edge words of the copy are not live after a resume. A dump of a saved copy shows: at `low`, alignment padding (0) below the `Wait.wait!` arguments, then the "x" argument (a small string, no refcount); at `top - 4`, a slot of the frames of `handle` that nothing reads after the wait. Measured: the copy can miss up to 24 words at the low end and 64 words at the top end with no wrong canary; 32 words at the low end give a wrong canary. A first version of the app with a record canary in each frame did not fail even with no restore at all: LLVM keeps those records in wasm locals (JSPI saves them), and the memory copies are never read again. Small strings are in memory, because their address goes to the builtins.

Cost (`node bench/sumcost.mjs bench/out/app.wasm 3000 5`: full app, variant b, 64 at once, waits that resolve at once, median of 5 runs, modes in turn, idle machine, load 0.9 on 24 cores):

| Items | `"off"` µs per request | `"afterAlarm"` | `"always"` | Sum checks per wait (`"always"`) | PLAN "Costs" |
|---|---|---|---|---|---|
| 200 | 223.9 | 222.3 (-0.7 %) | 225.2 (+0.6 %) | 1.0 | +1 %, +3 % |
| 2,000 | 2,003.8 | 2,046.8 (+2.1 %) | 2,086.0 (+4.1 %) | 1.0 | +3 %, +6 % |

The runs vary by about 3 % (200 items: 215 to 230 µs with no sums). Each resume checks, as "What happens at a resume" says: the `js_alloc` of the response block is an export call. 12f measures again.

Choices I made:

| Question | Answer |
|---|---|
| Where the sum check runs | In `waitEnd`, before the stack copy goes back (a call, so its frames are below the idle top, where the copy goes). The task's stack is not changed when a check fails. |
| What a failed check does | `alarm`: the cause goes into the `Wait` record, then a trap. The record stays in the table until `task_abort`, so a check between the trap and the catch in JS cannot mix two tasks. |
| `task_abort` result for an alarm | maxInt - cause. The pages are freed (`waitDrop`), as 12c wants. |
| Result in JS | Alarm at resume: `{ status: 503, alarm }`. An unclean trap keeps `{ trap }` with no status (the old tests and `bench.mjs` count it so). 12c gives it the 503. |
| `set_suspect` at an alarm | Called on the old instance, so the tasks that still resume on it check ("afterAlarm"). Until 12c, the replace cancels each task that waits; a task whose io ended before the replace still resumes there. |
| A trap in `task_abort` | Counts as an unclean trap (an alarm). Found by `wild.mjs` with "afterAlarm" and "off": `task_abort` trapped on a damaged instance, `run` threw, and the instance was never replaced (17,467 requests failed). |
| Block check | In modes 1 and 2 at each resume, not only when the epoch changed: it is a few table reads. Mode 0 has no check. |
| Exports that move the epoch | Each export that is not a pure getter. The getters (`live_bytes`, `task_waiting`, counters) do not. |
| Default sum mode of the host | 2, as `resumeCheck: "always"`. JS sets it before `init`. |
| Wild-write hook | Kind 5 (trap after its resume) is the default of `wild.mjs`. With kind 4 (trap at once, the research hook), JS replaces the instance in the catch of the writer before any timer resumes another task, and the replace cancels all waiting tasks. So kind 4 gives 0 wrong bodies also with sums off (measured: 0 at 16, 256, 4,096 words in all 3 modes), and the revert cannot fail. With kind 5, other tasks resume onto the damage first, as the old tasks did in the research harness. |
| `wild.mjs` request | `<id> 0 20 50` (depth 20, 50 items), so a run of 20,000 takes about 15 s |
| Owner check in realloc and `oomclean.mjs` | `oomclean.mjs` reallocated a block of task 7 with owner 0. That is now a miss and traps before the allocation, so the test lost its point (and left `FAIL_AT` set). The test now reallocs a block of owner 0 for the owner 0 case. |

`"afterAlarm"` in `wild.mjs` (kind 5): 2, 31, 85 wrong bodies at 16, 256, 4,096 words. This is the gap "With `"afterAlarm"`: a task resumes onto damage before the writer traps" of the table "Gaps": the research harness found 0 because its writer trapped at once.

Open points:

| Point | Detail |
|---|---|
| "Copy one word less" | No test can find it with this host and compiler: the edge words of the copy are not live (see the note). Decide: keep the test as it is (it finds a restore that misses 32 words or more), or change the PLAN text of the revert. |
| Other exports that trap on a damaged instance | `readRes`, `drainLog` and `res_free` after `handle` can also trap on a damaged instance. Then `run` throws. Only `task_abort` is caught now. 12c or 12d. |
| 12-pre map | `Wait` is now 48 B. New bench-only host globals: `WILD_BASE`, `WILD_SEED`, `WILD_WORDS`, `WILD_TRAP`, `POKE_OUT`, `POKE_OUT_ADD`. New host globals: `SUM_MODE`, `SUSPECT`, `SUM_CHECKS`, `ALARMS`, `RUN_EPOCH`. |

### Status of step 12-pre (2026-10-16)

Done. Script `research/memmap/memmap.mjs`, build with maps `research/memmap/build.sh`, output and method in `research/memmap/README.md` (full tables in `research/memmap/results/`). Run: `node research/memmap/memmap.mjs research/memmap/out/app.wasm` (also `app_deep.wasm`, and `app_boxy.wasm --light`). The memory map comes from an instance that runs 80 requests: waits, traps, cancels, a failed allocation, `dbg` lines, unclean traps, and in `app_deep` a stack overflow. Each byte that changes after `init` is found by a comparison at each phase.

Region table (bench app, 34 pages = 2,228,224 B at start, 0x000000 to 0x220000; the heap pool starts at 0x220000 and is empty after `init`):

| Region | Start | End | Size B | Written after init | PLAN 12 row |
|---|---|---|---|---|---|
| Stack guard | 0x000000 | 0x002000 | 8,192 | No (`app_deep`: 102 B in an overflow) | Shared stack |
| Canary | 0x002000 | 0x003000 | 4,096 | No (`init` writes it) | Constant data |
| Shared stack | 0x003000 | 0x100000 | 1,036,288 | Yes: used part 0x0d6f14 to 0x100000 | Shared stack |
| `.rodata` of host and Roc, `FREE_MARK` | 0x100000 | 0x100404 | 1,028 | No | Constant data |
| `SLOT_OWNER`, `TASKS` | 0x100404 | 0x103810 | 13,324 | Yes: 722 B | Allocator tables, task records |
| Host tables (`vtable`, `host`) | 0x103810 | 0x103850 | 64 | No | Constant data |
| Canary globals, `LOG`, counters | 0x103850 | 0x103874 | 36 | 12 B no, 16 B no, 8 B yes | Host globals |
| Unit tables, free-run index, pool bounds, `CACHE` | 0x103874 | 0x1d4b8c | 856,852 | Yes: 9,506 B | Allocator tables, task records, reserve table |
| Host globals (`TASK_*`, `COPY`, `TRAP_CLEAN`) | 0x1d4b8c | 0x1d4bb0 | 36 | Yes: 15 B | Host globals |
| `FILL` and `FILLED` (bench only) | 0x1d4bb0 | 0x214bb8 | 262,152 | Only by `heap_fill` | None (bench only, 7a) |
| `WAITS` | 0x214bb8 | 0x214fb8 | 1,024 | Yes: 253 B | Host globals |
| `FAULT_NEXT` (bench only) | 0x214fbc | 0x214fc0 | 4 | No | None (bench only, 7a) |
| Other host globals, host table | 0x214fb8 | 0x214fc8 | 12 | Yes: 1 B | Host globals, Constant data |
| Roc statics `roc_tail_pending`, `roc_tail_args` | 0x214fc8 | 0x2150a0 | 216 | Yes: 52 B | NONE |
| Unused tail | 0x2150a0 | 0x220000 | 44,896 | No | Free units (nobody writes) |

Heap units at the peak (64 tasks): 144 small and 2,800 large task units (row 1; 2,025,216 B of them are 64 saved stack copies, row 2), 1 host unit with the 64 `Wait` records (row 3), 1 JS unit (row 10), 19 free and 123 reserve units (row 5), 0 foreign units (row 9). Addresses of the first rows move with each build: the table is for the build of 2026-10-16 (`app.wasm` sha256 3b1a7e32...). `app_deep` has the same layout without `roc_tail_*`.

Result of the test: each region is in a row of the table "What a host bug can damage", with these exceptions:

| Region | Size | Note |
|---|---|---|
| Response block (host block from the return of `handle` to `res_free`) | 4 + body | In no row. 1 host unit exists in that window. |
| Roc statics `roc_tail_pending`, `roc_tail_args` | 212 B | Written by Roc code, in no table. Probably never live across a wait (to confirm). |
| Roc runtime statics (`app_boxy` only) | 352 B | Mutable, live across waits |
| Bench only: `FILL`, `FILLED`, `FILL_TAG`, `FAULT_NEXT` | 262,156 B | Not in a production build (7a) |

What is constant after `init`:

| What | Size | 12d |
|---|---|---|
| Constant data: `.rodata` (host and Roc), `FREE_MARK`, host tables, canary globals, canary | 5,204 B (app), 4,649 B (`app_deep`) | Sum after `set_free_mark` and `init`. Take the ranges from symbols, not addresses. |
| Row 8 (the rest of the host globals) | 1,096 B | Not constant (counters, flags, `LOG`, `OWNER`, `TASK_*`, `WAITS`). Range check. |
| Heap units at `init` | 0 | Nothing of the heap is constant |
| Foreign units | 0 in the bench apps. With the boxy runtime (`--specialize=no`): 0 at `init`, 416 after the first request, 896 after 16 at once; 805 of 896 do not change after they appear (3.3 MB), 91 change (mostly the first 4 KB of each 64 KB block); plus a constant blob of 826,296 B in its own section | Not set at `init`: sum when they appear. See the questions. |

What 12d must range-check or check by structure:

| Memory | Size | Check |
|---|---|---|
| Unit tables, free-run index, `CACHE`, `TASKS`, `SLOT_OWNER` | 870,176 B (only `POOL_LO` to `POOL_HI` is used) | Structure (as the step 12d text) |
| `OWNER`, `TASK_TOP`, `TASK_WAITING`, `TASK_SAVED`, `TRAP_CLEAN`, `COPY`, `LIVE_BYTES`, counters, `LOG` | 1,096 B | Ranges. `TASK_TOP` is 0 or in the stack. |
| `WAITS` (256 pointers), `WAITS_FREE_HINT` | 1,028 B | Each entry is null or in a host page; `at` = index; `TASK_WAITING` = number of entries; `TASK_SAVED` = sum of the copy lengths |

Other findings:

| Finding | Effect |
|---|---|
| `Wait` is not an `extern struct`. The script found the order low, top, copy pointer, copy length, out (2 words), owner, at (32 B) in all records. | 12a: make it `extern`, so that the sum of the fixed fields keeps its order |
| Foreign pages grow with the work of a request, not only at the start: 400 units for 5 items, 416 for 20, 768 for 100 (first request) | The text in section 4 ("mostly at start") is true only for small requests |
| The roc runtime takes pages after the first `js_alloc` in the bench apps, so there is no gap below `POOL_LO` | Keep the order. A runtime that grows before the first allocator call would make unmarked pages. |
| The name section does not exist in the production link (`--strip-all`). Symbols come from a wasm-ld map that `research/memmap/build.sh` makes. | 12d gets addresses from linker symbols in Zig |

Tests of the script (it must find bad data): a flipped byte in the constant data gives exit 1; a byte flipped in the unused tail gives exit 1; a missing rule gives exit 1 ("no row"); a map of another build gives exit 2 or is ignored. See `research/memmap/README.md`.

Questions for 12a and 12d:

| # | Question |
|---|---|
| 1 | Is the response block a row (row 8 or row 10), and which check covers it? |
| 2 | Is `roc_tail_args` never live across a wait? If yes, add a row "Roc code statics, no check". |
| 3 | Will talon use the boxy runtime? If not, the foreign rows and the runtime statics are empty. |
| 4 | With the boxy runtime: when does 12d sum the foreign units, and how does it skip the units that change? |
| 5 | Is `WAITS` a "host globals" item (the PLAN says "task ids")? |

Decisions on the 12-pre findings (2026-10-16):

| Finding | Decision | Why |
|---|---|---|
| `Wait` field order | 12a makes `Wait` an `extern struct` | The sum of the fixed fields needs a fixed order |
| Response block (owner 0, from the return of `handle` to `res_free`) | New row in "What a host bug can damage": no check | JS reads it and calls `res_free` at once after `handle` returns (`readRes` in `bench/core.js`). No other export runs in that window. 8a must keep this order. |
| `roc_tail_pending`, `roc_tail_args` | New row: "Roc code statics, no check" | A member of a tail group writes them just before it returns to the tail driver, and the driver reads them at once (`roc:src/backend/llvm/MonoLlvmCodeGen.zig:2250`). No call, so no wait, is between the write and the read. |
| `WAITS` | Part of "Host globals". 12d checks: each entry is null or points into a host page, `at` equals the index, `TASK_WAITING` equals the number of entries, `TASK_SAVED` equals the sum of the copy lengths. | |
| Foreign units | 12d sums no foreign unit, and checks only their table entries | None exist after `init`. The bench apps and talon use the default build (no boxy runtime), which has none at all. With `--specialize=no`, they appear at the first requests and some change. |
| Order of `poolInit` | An invariant that 12d checks: no foreign unit below `POOL_LO` | `poolInit` runs at the first `js_alloc`, before the roc runtime takes pages |
| Constant data | 12d sums it after `set_free_mark` and `init`. The ranges come from linker symbols, not fixed addresses. | `FREE_MARK` is set by JS before `init` |

## Done when

- All tests above pass, and each fails when its change is reverted (the exceptions are in "Order of work").
- `bench/node-test.mjs` and the leak test still give 0 bad bodies and live bytes 0.
- DESIGN.md §6.1, DESIGN-REGISTRY.md §8 and `bench/README.md` show the new rules: stack-first, the task table, cancel, the memory management of problem 4, one instance per isolate with the checks at resume (12), the CPU signals, the platform API (8, `API.md` phases A and B), the shim (9), body handles (10) and the release (11).
