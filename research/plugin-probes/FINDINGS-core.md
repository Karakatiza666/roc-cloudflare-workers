# Findings: the core contract (roc-syntax-mcp plugin)

Probes for the roc-syntax-mcp plugin `plugins/cloudflare-workers`. Each probe pins a local bundle of `platform/` at commit 703a519 (`URL`), checked with nightly-2026-10-12-2664a27 (`env.sh`). The bundle is in the Roc package cache, so `roc check` does not download it.

| # | Finding | Found by | Kind |
| --- | --- | --- | --- |
| C1 | A URL with the version `0.0.0` is refused: "uses the reserved version 0.0.0. The lowest publishable package version is 0.0.1". `scripts/bundle.sh` uses `0.0.0-local` when HEAD has no tag, so its `url:` line gives an app that does not check. | `p1_entry.roc` with `0.0.0-local` | Compiler |
| C2 | `Time.now_ms!`, `WebCrypto.random_uuid!`, `Body.writer!`, `Ctx.pass_through!` (and `Native` `open!`, `new!`) take `{}`. A call with `()` is "too few args". | `p3_time.roc`, `p11_unit.roc` | Compiler |
| C3 | `req.json!()` into a value with no annotation: the error is at `worker = Worker.{ fetch! }`, "missing method parser_for" on `{ name: _field }`, not at the read. Annotate the value. | `p4_json.roc` | Compiler |
| C4 | A tag is not a function: `.map(Got)` gives "[Got]" where `Response -> b` is needed. Write `.map(\|r\| Got(r))`. `API.md` 6.5 and `MODULES.md` 11 show `.map(Got)`. | `p8_misc.roc` | Compiler |
| C5 | With no annotation on `fetch!`, `req.method` makes `req` a structural record, so `req.segments()` is "missing method segments" on `{ method: _field, .. }`. With only `req.segments()` (no field read), no annotation is needed. | `p8_misc.roc` | Compiler |
| C6 | `Try(Response, [])` on one handler closes the one error type `e` of `Worker(e)` for all handlers. A second handler with errors gives "invalid nominal record" with the two full records. Write `_`. | `p9_join.roc` | Compiler |
| C7 | A `Secret` has no `encoder_for`, so a `Secret` in a `Log.info!` record does not compile. `secret.reveal()` gives the `Str`. By design (`MODULES.md` 10). | `p7_queue_memo.roc` | Compiler |
| C8 | The entry is `event!`, not `main!`: "The platform expects your app module to expose a definition named event!". | `p10_bad_entry.roc` | Compiler |
| C9 | Not a finding: a `scheduled!` that calls `no_retry!` checks with no annotation on nightly 10-12. `MODULES.md` 3 ("Annotation") says that it needs `Worker.Scheduled => Try({}, e)`. | `p1_entry.roc` | Doc is stale |
| C10 | Not a finding: `db.first!` with no annotation checks when the use of the fields fixes their types (`p2_d1.roc`), and `Kv.json` with no annotation checks too (`p8_misc.roc`). | | |
| C11 | A helper that matches each of its errors and is annotated `Try(Response, _)` infers the closed `Try(Response, [])`. A `match` arm of `fetch!` that gives it as it is closes the error type of `fetch!`, so the next `?` in `fetch!` fails, and each other handler of the `Worker` gives "invalid nominal record". Fix: the helper gives a `Response`, or the arm is `Ok(helper!({})?)`. | `p12_closed_a.roc`, `p12_closed_b.roc` | Compiler |
