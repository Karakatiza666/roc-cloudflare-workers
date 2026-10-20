# `roc check` against `roc build`: REVIEW.md N2 does not reproduce

Date: 2026-10-20. Source: `examples/auction/REVIEW.md` row N2. It says that `roc check` gave "No errors found" for `web.roc`, but `roc build --target=wasm32` of the same files gave 2 type errors.

Result: not reproduced on 3 nightlies. `roc check` reports the same 2 errors as `roc build` in each case below. No upstream issue was filed.

## The 2 bad lines

| File | Line | Bad code | Good code (`examples/auction/`) |
| --- | --- | --- | --- |
| `web.roc` | 150 | `req.body` | `req.body()` (the `Request` is opaque and has methods) |
| `LotRoom.roc` | 72 | `bidder_slot.set!(socket, { name })?` | `bidder_slot.set!(socket, { name: name })?` (`{ name }` is a block, so its type is `Str`) |

## Results

`run.sh` copies `examples/auction/*.roc` to `gavel/`, puts the bad lines back, and runs each case. The output has a summary line for each case.

| Case | 2026-10-12-2664a27 | 2026-10-18-1df370f | 2026-10-19-601b54c (latest) |
| --- | --- | --- | --- |
| `check --no-cache web.roc` | 2 errors | 2 errors | 2 errors |
| `build --target=wasm32 --no-cache web.roc` | SIGSEGV (REVIEW.md N1) | SIGSEGV (N1) | 2 errors |
| `check --no-cache ledger.roc` | No errors | No errors | No errors |
| `check web.roc`, good files (cache becomes warm) | No errors | No errors | No errors |
| `check web.roc`, then the bad lines, with that cache | 2 errors | 2 errors | 2 errors |
| tiny platform: `check app.roc`, `Req :=` (cache becomes warm) | No errors | No errors | No errors |
| tiny platform: `check app.roc`, `Req ::`, with that cache | 1 error | 1 error | 1 error |
| tiny platform: `check --no-cache app.roc`, `Req ::` | 1 error | 1 error | 1 error |

Other cases, run by hand on 2026-10-12 and 2026-10-19:

| Case | Result |
| --- | --- |
| The repository at commit `2170a9e` (platform of that day) with the 2 bad lines | `check`: 2 errors |
| `check` in `examples/auction/` (not from the root) | 2 errors |
| Cache warm from commit `abaae9d` (old platform: `Request :=` with a `body` field), then `2170a9e` with the bad lines, `check` with the cache | 2 errors |
| 15 `check` runs with the cache, 8 runs with `--no-cache` | 2 errors each time |
| `check` with the default cache (`~/.cache/roc`) | 2 errors |
| `roc_check` of the roc-syntax MCP server | 2 errors |
| A headerless app with a local module whose function type changes, `check` with the cache | 1 error |

## Hypotheses

| Hypothesis | Status |
| --- | --- |
| `check` of an app does not type-check modules that the app imports (`LotRoom.roc`) | Rejected: `check` reports `LotRoom.roc:72` |
| `check` does not type-check use sites of platform types | Rejected: `check` reports `web.roc:150` |
| A stale cache entry, after a platform type changed from `:=` to `::` | Not reproduced (gavel and tiny platform) |
| The check was of a different file: `ledger.roc` does not import `LotRoom.roc` and has no bad line, so it gives "No errors found" | Possible. No evidence either way |
| The check was before the edit that added the bad lines | Possible. No evidence either way |

## Files

| File | Use |
| --- | --- |
| `run.sh` | The cases of the first table. Arguments: one or more paths to `roc` |
| `app.roc` | Tiny app: `handle! = \|req\| req.body` |
| `plat/main.roc` | Tiny platform that exposes `Req` |
| `plat/Req_v1.roc` | `Req := { body : Str }` (field access is OK) |
| `plat/Req_v2.roc` | `Req :: { body : Str }` with a `body` method (field access is an error) |

## Run

From the submodule root:

```sh
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
research/check-vs-build/run.sh $(bench/get-roc.sh nightly-2026-10-19-601b54c)
```

`run.sh` uses its own cache dir (`out/cache`) for the cache cases. It removes `gavel/` and `out/` at the end.

## Next

If `roc check` gives "No errors found" again where `roc build` gives errors, record at once: the command, the current directory, the file, the cache dir, and `git status`. Then copy the files here.
