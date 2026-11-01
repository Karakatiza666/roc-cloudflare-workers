# The oldest supported nightly (2026-11-02)

Question (Talon registry, `docs/registry/PLAN.md` E4): which Roc nightlies build and run this platform? The answer is `min_nightly` of `js/cfw.json`.

Method: `bench/build.sh` with the release nightly (2026-10-31, f7bef6b) makes the hosts and the glue. Then `try.sh <tag>` builds `conformance/app.roc`, `bench/app.roc`, `bench/app_prod.roc` and `bench/app_b3.roc` with the older nightly against those hosts (the glue is not made again), and runs the tests that take a wasm file. Output: `.cache/min-nightly/<tag>/`.

| Nightly | Conformance build | Layout | Stack exports | `node-test` | `handler-test` | `exports-test` | Conformance run |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-31 (f7bef6b) | 0 errors, 0 warnings | STACK-FIRST | 3 | pass | pass | pass | 489 passed |
| 2026-10-27 (de79a0f) | 0 errors, 0 warnings | STACK-FIRST | none | pass | pass | fail: only the 3 compiler exports | 489 passed |
| 2026-10-21 (5349569) | 0 errors, 0 warnings | STACK-FIRST | none | pass | pass | fail: only the 3 compiler exports | 489 passed |
| 2026-10-19 (601b54c) | 0 errors, 0 warnings | STACK-FIRST | none | pass | pass | fail: only the 3 compiler exports | 489 passed |
| 2026-10-18 (1df370f) | SIGSEGV in the compiler (`post-check monotype`) | not run | | | | | not run |
| 2026-10-14 (38a3029) | SIGSEGV in the compiler (`post-check monotype`) | STACK-FIRST (`app.wasm`, `app_prod.wasm`) | none | pass | pass | fail: only the compiler exports | not run (no wasm) |

Result: `min_nightly` is `nightly-2026-10-19-601b54c`. The `bench/app.roc` builds exit with 2: the `dbg` warning of that app (on purpose). 2026-10-15 was not run: it is older than a nightly that crashes.

The `exports-test.mjs` failures on the older nightlies are the 3 exports that the compiler adds from 2026-10-28 (`__stack_pointer`, `__stack_low`, `__stack_high`). The platform does not use them, so they do not change the support. `sync` uses them as the proof that a wasm is from 2026-10-28 or later (`MODULES.md` 3, "`sync`, the Roc nightly").
