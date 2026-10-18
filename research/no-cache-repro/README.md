# Roc build cache: warm build differs from a cold build

Result: NOT FILED upstream. The bytes differ, but no wrong behavior is shown in a small case.

History: `PLAN.md` ("Status of steps 11a, 11b", Findings) says `examples/hello/app.roc` is 475,805 bytes cold and 461,058 bytes warm (wasm32).
Two cold builds are equal. All scripts use `--no-cache` since then.

## What `repro.sh` shows

`repro.sh [tag]` builds `main.roc` (imports `Lib.roc`, a top-level `List(U64)` constant) with a private empty cache.

| Build | Result (nightly-2026-10-12-2664a27 and nightly-2026-10-18-1df370f) |
|---|---|
| first build (empty cache) | same bytes as `--no-cache` |
| second build (warm cache) | 32 bytes smaller, one static data block less (`roc__d*` symbols 2, not 3) |
| warm build after an edit of `Lib.roc` | same bytes as `--no-cache` |
| output of all builds | equal (`19`), same `roc_alloc` count under gdb |

Exit code 1 means the warm binary differs from the `--no-cache` binary. It does so on both nightlies, with `--opt=dev`, `speed` and `size`.

Also seen with the real app (wasm32, pinned nightly): the warm build has 367 functions and 477,293 bytes of code. The cold build has 374 functions and 487,026 bytes.
No behavior difference was shown there either (not run in workerd).

## Why it is not filed

- No observable difference in the small case: only data layout. A filed issue would claim "wrong binary" without proof.
- The cause in the real app (7 functions, 9.7 KB of code) is not reduced.
- Close existing issues, all CLOSED: #12294 (warm build rebuilds a static closure on the heap), #12241 (cached build allocates more), #11627, #11826. Open: #12373 (constants in optimized object packs).
  The maintainers treat cache-dependent output as a bug when a count or a value shows it.

To file: find a program where the warm build gives a different run-time result (value, allocation count, crash). Start from the wasm app: diff the 7 functions.

## Follow-up: is the warm binary wrong? (pinned nightly)

| Check | Result |
|---|---|
| Functions of `examples/hello` (`--debug` names), cold against warm | Cold has 7 more functions. Almost all are `roc_llvm_rc_incref/decref_N` helpers. Their numbers shift between the builds, so a name diff is noisy. 4 `roc__p<hash>.fast` procs differ in each build (different hashes). |
| `conformance/app.roc` (`--opt=speed --target=wasm32`), cold 10,471,559 bytes, warm 10,412,125 bytes, `--no-cache` 10,471,559 bytes | The warm file is 59 KB smaller. `--no-cache` equals the cold file. |
| `node conformance/run.mjs` on the warm wasm | 367 passed, 0 failed (exit 0) |
| `node conformance/run.mjs` on the `--no-cache` wasm | 367 passed, 0 failed (exit 0). The same two log lines about `KvOnly` and `Ghost` appear in both (they are expected checks). |

Conclusion: no run-time failure from a warm build was found. The "--no-cache is required" advice in `README.md` is too strong as a correctness rule.
It is justified as "reproducible bytes" (the cached file differs from the clean file). One conformance run is not proof that the warm binary is right.
Nothing was filed.
