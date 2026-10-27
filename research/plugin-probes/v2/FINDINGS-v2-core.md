# Findings v2: the core contract at HEAD (roc-syntax-mcp plugin repin)

Probes for the repin of the roc-syntax-mcp plugin `plugins/cloudflare-workers` (2026-10-26). The pin is the local bundle `0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst` of the working tree at commit eb8a1ab (`URL`), checked with nightly-2026-10-19-601b54c (`env.sh`). The run-time apps ran in `wrangler dev --local` only. Nothing was deployed.

Kind: Compiler, Runtime (local workerd), Tooling, or Silent (it compiles and does the wrong thing).

| # | Finding | Found by | Kind |
| --- | --- | --- | --- |
| V1 | The manual setup works with no npm: `roc build`, `cp -r ~/.cache/roc/packages/<hash>/js .roc-cfw`, `node .roc-cfw/cli.mjs sync`, `wrangler dev --local`. | `project/` | Runtime |
| V2 | `Time.now_ms!({})` and `Body.writer!({})` are "too many args" (MC14: `()`). A lambda `\|{}\|` where `() =>` is needed is a mismatch. | `p1f`, `p3f`, `p6_unit_lambda` | Compiler |
| V3 | An unannotated `fetch!` that calls `req.method()` and `req.segments()` checks. A field read `req.method` gives two errors, the second at `Worker.new`, far from the cause. | `p1a`, `p1b` | Compiler |
| V4 | `Worker.new({ fetch! })` (one-field block) is a mismatch at `Worker.new`. `Worker.{ fetch! }` is "cannot use opaque nominal type". | `p1c`, `p1e` | Compiler |
| V5 | Each handler has its own error type: `Try(Response, [])` and `Try({}, [UnknownCron(Str)])` in one `Worker.new` check. The log line names the error of that handler. | `p1d`, `project_worker` | Compiler, Runtime |
| V6 | An unannotated `req.json!()?` whose use does not fix the type is "encoder_for ... never resolved" at the read. A use that reads a field (`ask.name`) fixes the type. | `p2a`, `p1i`, `p7b` | Compiler |
| V7 | Old C11 still holds, with a narrower trigger: a helper whose `match` gives `Ok` in each arm, annotated `Try(Response, _)`, infers `[]`. An arm of `fetch!` that gives it as it is closes the errors of `fetch!`. A helper with a plain `Ok(...)` body is fine. Fix: the helper gives a `Response`, or `Ok(helper!()?)`. | `p2c`, `p2c2`, `p2c3`, `q1` to `q4` | Compiler |
| V8 | A handler that is defined and not listed in `Worker.new` is never called. No warning, and `sync` does not see it. **Fixed (2026-10-26)**: `sync` reads the app source (`--file`, default `<wasm name>.roc`, else `main.roc`) and prints `sync: main.roc:12: scheduled! is defined but Worker.new does not list it; it never runs` for each top-level handler def (`fetch!`, `scheduled!`, `queue!`, `email!`, `tail!`, `other!`, `init!`, `alarm!`, `web_socket_*!`) that the manifest does not list and the code does not use. Exit 0; `sync --check` exit 1. `other` is now in `handlers` of the manifest. `MODULES.md` 3, "A handler that is not listed". | `p1j` | Silent |
| V9 | `.map(Got)` does not compile: a tag is not a function. | `p1h` | Compiler |
| V10 | `Ctx.respond!` is gone. `Response.from_body(...).after(...)` with a writer from `Body.writer!()` streams SSE. | `p3b`, `project_http` | Compiler, Runtime |
| V11 | A request body read in the work of `Response.after` compiles. At run time it is `BodyErr` ("Can't read from request stream after response has been sent"), seen only in the log. | `p3e`, `project_worker` | Runtime |
| V12 | `Ctx.wait_until!` takes only `Io({}, e)`. `Io.pin!` is gone: use `Js.pin!`, `Js.pinned!`, `Js.unpin!`. | `p4a` | Compiler |
| V13 | The op tags (`Get`, `Call`, `Root`, `Slot`, `Lit`, `Text`) need no import. | `p4b` | Compiler |
| V14 | `Io.sync` with a promise gives `PromiseInCall` ("the program needs await!"). The `ops` functions and the pin work with `Io.new`. | `project_escape` | Runtime |
| V15 | `Log.info!` with a `Secret` is "encoder_for ... Secret" (by design). | `p7c` | Compiler |
| V16 | A `U64` SQL parameter binds as it is (`[s.time_ms()]`): no `to_i64_wrap`. A bare `[]` gives a misleading "never resolved" error at the call: use `Sql.none`. | `p5a`, `p7a` | Compiler |
| V17 | The D1 constraint error is `Err(Infra(Constraint(..)))`. The flat pattern `Err(Constraint(..))` also compiles and never matches. Fixed 2026-10-26: see "Fixed after the probes" | `p7d`, `p7e` | Silent |
| V18 | A cron run goes to the `Worker.cron` handler of the same expression. Each other run goes to `scheduled!`. `sync` checks `triggers.crons`. | `project_worker` | Runtime |
| V19 | `WebCrypto.hmac_sha256(key, data)` equals `openssl dgst -sha256 -hmac`. The webhook route gave 204 for a good signature and 401 for a bad one. | `project_http` | Runtime |
| V20 | A `Try` has no codec as an RPC `ret`. The `err` of a method must hold the platform tags that its body raises: `Rpc.NoErr` fails, `[Infra(Rpc.Infra)]` works. | `p9a`, `v1_snippets` | Compiler |
| V21 | `sync` and `sync --check` exit 1 for an entry file that `sync` did not write. An app with `makeHandler` options (`ops`) must write `worker.js` by hand, so `sync` cannot be in its build script. `--force` writes over the file. **Fixed (2026-10-26)**: a file `worker.options.js` next to `worker.js` (its default export is the options object) is imported by the `worker.js` that `sync` writes, as `makeHandler(app, options)`. `sync --check` checks the import. `sync` never writes the options file. With no options file the output does not change. `MODULES.md` 3, "The options file". | `project_escape` | Tooling |
| V22 | `plugin validate` needs the nightly at the roc-syntax-mcp repo root (`roc_nightly-linux_x86_64-2026-10-19-601b54c/`, a git-ignored symlink now). The global `roc-syntax-mcp` command has its own root: use `npm run plugin -- validate` in the checkout. | validate runs | Tooling |
| V23 | Not seen at HEAD: the Memo "type not determined" limit for an unannotated `load!` (`MODULES.md` about line 1644). | `p8a`, `p8b`, `p8c` | Compiler |
| V24 | With no network, a DNS failure of `Http.send!` is `Infra(Network("internal error; reference ..."))`. | `project_http` | Runtime |

## The old findings (`../FINDINGS-core.md`) at HEAD

| Old | State |
| --- | --- |
| C1 (`0.0.0` version) | Still a Roc rule. `scripts/bundle.sh` now defaults to `0.0.1-local` |
| C2 (`{}` for no argument) | Gone (V2) |
| C3 (JSON read error far away) | The error is now at the read (V6) |
| C4 (`.map(Got)`) | Still true (V9). `MODULES.md` is fixed |
| C5 (unannotated `fetch!`) | Fixed for methods. A field read still fails far away (V3) |
| C6 (`Try(Response, [])` closes all handlers) | Fixed (V5) |
| C7 (`Secret` has no codec) | Still true, by design (V15) |
| C11 (closed helper) | Still true, narrower trigger (V7) |

## Fixed after the probes (2026-10-26)

Not committed, not released. The plugin pin is still the old bundle, so the probes `p7d` and `p7e` show the old shape. `PLAN.md`, "Status of the v2 probe fixes (2026-10-26)", has the tests and the reverts.

| # | State | How |
| --- | --- | --- |
| V17 | Fixed | A constraint failure is the flat `Err(Constraint({ kind, message }))`, beside `Infra([...])`, in each D1 function (also `batch!`, `exec!`, the `_with` forms, the twins, `D1.Session`) and in `Object.Self` `sql!`, `sql_run!`, `sql_rows!` (`platform/D1.roc` `thrown`, `read_error`; `platform/Object.roc`). `Rpc.Infra` does not have `Constraint` now (28 tags): a method that passes it on lists `Constraint(Sql.Constraint)` in its `err`. The old pattern `Infra(Constraint(_))` is a compile error at a closed type (an `Rpc` err, an annotated handler) and never matches at an open type. Checks: `conformance/checks/d1.mjs` "d1 V17: ...", the 8d checks, `objects.mjs`, `rpcerr.mjs` |

## Probes for plugin 0.0.2 (2026-10-26, 2026-10-27)

The `r_*` probes check the V17 fix. Their header pins the release bundle `0.0.1` (`GcDNxAwP...`). The `s_*` probes prepare plugin 0.0.2. Their header pins the release bundle `0.0.2` (`5xpAVbae...`). Result: `roc check` with nightly-2026-10-26-3c0fffe (exit code). With the `0.0.1` bundle each check also gives the warning "The type Range shadows a builtin type" (`R2.roc`), so 0 errors gives exit 2.

| Probe | What it shows | Result on 10-26 |
| --- | --- | --- |
| `r_constraint` | The old pattern `Err(Infra(Constraint(_)))` and the new `Err(Constraint(_))` both compile at an open error type (`_`) | 0 errors (exit 2) |
| `r_constraint2` | The old pattern alone compiles at an open type, so it never matches and nothing tells the user (V17, Silent) | 0 errors (exit 2) |
| `r_constraint3` | The old pattern at a closed type `[Constraint(Sql.Constraint), Infra([D1Err(Io.Thrown)])]` is a compile error | 1 error: type mismatch at `Err(e) => Err(e)` (exit 1) |
| `r_rpc_no` | An RPC method with `err` `[Infra(Rpc.Infra)]` cannot pass on `sql_run!?`: `Rpc.Infra` has no `Constraint` | 1 error: type mismatch at `add_hit.on` (exit 1) |
| `r_rpc_yes` | The same method with `err` `[Constraint(Sql.Constraint), Infra(Rpc.Infra)]` compiles | 0 errors (exit 2) |
| `s_r2_range_old` | `R2.Range` is gone in 0.0.2 (now `R2.ByteRange`): old code gets a clear error | 1 error: "The type Range is not exposed by the module pf.R2" (exit 1). Same on 10-19 |
| `s_memo_const` | A `Memo` constant whose `get!()?` joins with `D1` errors in a function with a closed error type (`[Constraint(Sql.Constraint), Infra(Faults)]`) | 0 errors (exit 0). Same on 10-19 |
| `s_memo_fn` | The same app with each `Memo` as a function (`tables().get!()?`), the form of `MODULES.md` 9 | 0 errors (exit 0). Same on 10-19 |

`s_memo_const` does not show the 10-26 type mismatch of `MODULES.md` 9 and `PLAN.md` ("Nightly 2026-10-26, second error"): with this closed error type, the constant also checks on both nightlies.
