# Audit of the public surface before release 0.0.10

| Item | Value |
| --- | --- |
| Date | 2026-11-11 |
| Tree | worktree agent-aed6b1885d438de15, branch cbor-0.5.0, HEAD ebfb13f plus the uncommitted edits of the release agent |
| Method | Read only. The docs (README.md, MODULES.md, API.md, js/template/, research/design-notes/test-helper.md, .github/release-notes.md, the `##` comments in platform/*.roc) compared with the code (platform/*.roc, js/*.js, cli.mjs, test.mjs). Scripts checked each `Module.name` in the docs against the code, and each signature in the code blocks of MODULES.md and API.md. |

Columns: Sure = sure / likely / check. README line numbers are from 2026-11-11 and can move.

## Summary

| Severity | Count |
| --- | --- |
| Blocker | 5 (B1 fixed during the audit; check it) |
| Should fix | 14 |
| Nice to have | 17 |
| Missing Workers features (section 4) | 13 rows |

- Code-block signatures in MODULES.md agree with the code (only `Thrown` vs `Io.Thrown`, `where` clauses, the `Worker.Binding` alias and tag order differ).
- Each `Module.name` in README, MODULES.md and API.md exists, except names the docs mark as removed or not built, and N3, N4.
- No exposed function is missing from MODULES.md.

## 1. Blockers

| # | File:line | What is wrong | Sure | Fix |
| --- | --- | --- | --- | --- |
| B1 | platform/main.roc:8, bench/platform/main.roc:8 | At the start of the audit the `cbor:` package was an absolute local path. bundle.sh copies platform/*.roc as they are, and its check does not read the header, so such a bundle does not build on another machine. The release agent then changed it to the roc-cbor 0.5.0 URL. | sure | Confirm that the 0.5.0 release is 5366ccd and that main.roc, bench/platform/main.roc and examples/hello/with_cbor.roc have the same URL. Add a bundle.sh check: fail when a `packages` value in main.roc does not start with `https://`. |
| B2 | js/template/main.roc:8, :28, :52-56 | The template that `roc-cfw init` writes has the route `/fetch?url=U`, which fetches any URL from the client. The template `deploy` script puts it on a public workers.dev URL, so each new project is an open fetch relay (SSRF). With `global_fetch_strictly_public` it can also reach other Workers on workers.dev. | sure | Remove the route from the template, or fetch one fixed URL. Keep the open form only in examples/hello/, with a warning comment. |
| B3 | README.md:5, :23-34, :38 | Line 5 says "The latest release is 0.0.9". No 0.0.10 URL row. The title is "Changes in 0.0.10 (not released)". | sure | After the release run: add the URL and nightly, change line 5, remove "(not released)". |
| B4 | .github/release-notes.md:25 | The release body says "It wraps roc-cbor 0.2.3" and does not point to the migration. | sure | Change to 0.5.0. Add: "0.0.10 changes the CBOR format of stored data: read README 'Changes in 0.0.10' and MODULES.md 1 'Migration of stored data' before the deploy." |
| B5 | js/cfw.json:1, README.md:157-165 | `min_nightly` is nightly-2026-10-19-601b54c, checked 2026-11-02 with roc-cbor 0.2.3. Nothing shows that 10-19 builds the platform with roc-cbor 0.5.0. | check | Build test-helper/app with nightly 2026-10-19 and roc-cbor 0.5.0 (one capped job). If it fails, move `min_nightly` up and update "Supported nightlies". |

## 2. Should fix

| # | File:line | What is wrong | Sure | Fix |
| --- | --- | --- | --- | --- |
| S1 | platform/Sql.roc:61-66 | The `Sql.or_null` comment says `Sql.null`, `Sql.or_null` and `Err(Null)` "write no key (roc-cbor 0.2.2)". In 0.0.10 they write `null`. | sure | "writes null. A cell, an attachment and Memo read it as Err(Null). RPC and queue reads (Cbor.js_values) read it as no key: use x ?: a or Try(a, [Missing])." |
| S2 | MODULES.md:249 | Says "with roc-cbor 0.2.3 ... right in a dev build", names nightly 2026-10-31. | sure | Copy README:319; add the dev flag `--wasm-stack-size=2097152`. |
| S3 | js/template/main.roc:58-59 | "the shim checks env.DB at load" is wrong since 0.0.7 (first event). | sure | "at the first event". |
| S4 | js/template/main.roc:1 | "The example Worker (PLAN.md 11b)": users have no PLAN.md. | sure | Neutral first line. |
| S5 | js/template/talon.toml:3-7 | Build and check steps have no `ok-exit = [2]`; one compiler warning stops build, dev and deploy. | likely | Make `ok-exit = [2]` the default for the build step. Confirm that the released roc-cfw writes it. |
| S6 | README.md:184-190 | "Version that was checked (2026-10-27)": Talon 0.0.1, platform 0.0.1, nightly 10-27; transcript shows "1 warning". | sure | Run the steps again with 0.0.10 and the current Talon; replace table and transcript. |
| S7 | README.md:257-263 | "Gaps of the released versions (2026-10-27)" is about 0.0.1; both gaps are closed. | sure | Delete it, or keep one line in "Changes in 0.0.2". |
| S8 | README.md:157, :161 | Calls 2026-10-31 "The release build"; releases since 0.0.8 use 2026-11-06. "Checked 2026-11-02 against 0.0.3". | sure | Add the 0.0.10 build nightly as the release build; give the date and version of the last check (B5). |
| S9 | README.md:286 | "(for 0.0.2, the URL in 'What a release has')". | sure | "the URL of the latest release". |
| S10 | MODULES.md:849 | "Object.Self SQL: Not built" is wrong; `sql!`, `sql_rows!`, `sql_with!`, `sql_rows_with!` exist (Object.roc:220-235). | sure | Remove the row or say "Built". |
| S11 | js/cli.mjs:477-578 | `sync` checks only the top level of the Wrangler config; Wrangler does not inherit bindings into `[env.<name>]`, so `deploy --env production` can lose a binding that `sync` passed. | sure | Add `sync --env <name>`, or print a note when the config has an `env` table. |
| S12 | API.md:5, :12-56 | README calls API.md "The app API", but it is "Draft 4, 2026-10-15" and section 1 audits the Talon registry and links to files not in the public repo. | sure | A first line saying section 1 is history; or move section 1 to research/. |
| S13 | MODULES.md:1819 vs :1801-1810, :1849 | Row 1819 says "Do not use StartTls until then"; other rows say it is fixed (EP11). | check | "Local: works since EP11. Edge: not tested again." |
| S14 | research/design-notes/test-helper.md:3, README.md:372 | Note says helper "not released"; README says TH1 to TH19, but TH20, TH21 exist. | sure | Update the state line; README to TH1 to TH21. |

## 3. Nice to have

| # | File:line | What is wrong | Sure | Fix |
| --- | --- | --- | --- | --- |
| N1 | MODULES.md:109 | "roc-cbor 0.2.2 writes a Dec": old version. | sure | "0.2.2 and later". |
| N2 | MODULES.md:237 | Example calls undefined `build!(job)`. | sure | Add a stub. |
| N3 | API.md:342-357 | Uses `Sql.rows_from_js`, which does not exist; error type lacks `Constraint`, `TooLarge`. | sure | Mark as sketch or copy the real `rows`. |
| N4 | API.md:180 | Calls `Body.Stream(Js.Ref)` a type; it is a tag of `Body`. | sure | Fix wording. |
| N5 | README.md:440 | "the bundle and the shim package": no shim package. | sure | "# dist/: the bundle". |
| N6 | js/index.js:16 | "js/cli.js (sync, init)": file is cli.mjs, `init` moved to roc-cfw. | sure | Fix the line. |
| N7 | js/cli.mjs:858-862, js/bindings.js:45 | For wrangler.json(c), `sync` prints "(as JSON)" and then TOML. | sure | Print JSON. |
| N8 | js/cli.mjs:250 | `parseJsonc` trailing-comma regex also runs inside strings. | likely | Remove commas in the string-aware scan. |
| N9 | js/cli.mjs:572-576 | Raw `event!` app with `triggers.crons` gets `wrong` and exit 1. | likely | Make it a note when `got === null`. |
| N10 | README.md:399, js/test.mjs:597-601, :347 | `app.queue(name, ...)` takes the queue name, not the binding name; not documented. | likely | Document it. |
| N11 | README.md:395-409, js/test.mjs:621-646 | `app.takeTrace()`, `app.manifest`, `app.token`, `res.request` not in the table. | sure | Add, or mark unstable. |
| N12 | js/test.mjs:445-456 | After a failed seed batch the one-at-a-time rerun leaves partial or full state. | likely | Document it, or a clear "seed is partial" text. |
| N13 | js/manifest.js:56-66, MODULES.md:427 | Error texts name `on_trap.crash`; the field is `crashed`. | sure | Write `crashed`. |
| N14 | .github/release-notes.md:13 | `tln add --platform ...@<tag>` vs README `tln init --platform`. | check | Use the README command or both. |
| N15 | AUDIT.md, design_issues_tmp.md | Internal October notes at the repo root. | sure | Move to research/. |
| N16 | MODULES.md:1887, Version.roc:3, Hyperdrive.roc:19 | `Version.metadata!`, `Hyperdrive.config!` crash (500) with no binding (decided, OO1). | sure | Say so in the `##` comment. |
| N17 | platform/*.roc | About 170 exposed functions have no `##` comment (list below). | sure | One line each. |

N17 list:

| Module | Functions |
| --- | --- |
| Request | `method`, `url`, `headers`, `body`, the 18 cf readers (`asn` to `client_tcp_rtt_ms`), `get`, `post`, `with_header`, `with_method`, `with_url`, `with_body`, `text!`, `json!`, `bytes!`, `bytes_with!` |
| Response | `status`, `headers`, `body`, `with_status`, `with_body`, `from_status`, `redirect`, `with_header`, `text!`, `json!`, `bytes!`, `bytes_with!` |
| D1 | the `_with` forms (`all`, `all_tuples`, `first`, `rows`, `batch`); every `D1.Session` function; `Result.info`, `Result.all`, `Result.parsed` |
| Kv | `get_with_metadata_with`, `delete`, `Metadata.of`, `Cell.get`, `Cell.set`, `Cell.delete` |
| Queue | `send_batch_with`, `Batch.queue`, `Batch.messages`, `Batch.retry_all!`, `Message.id`, `Message.timestamp_ms`, `Message.attempts`, `Message.body`, `Message.retry!`, `Message.retry_with!` |
| Object | `Namespace.named_with`, `Namespace.from_id_with`, `Self.sql_with!`, `Self.sql_rows_with!`, `Self.delete_alarm`, `Self.list_with!`, `Class.name` |
| Workflows | `Instance.id`, `Instance.status`, `Instance.pause`, `Instance.resume`, `Instance.terminate` |
| Vectorize | `query`, `query_with`, `upsert`, `delete` |
| R2 | `create_multipart_upload`, `create_multipart_upload_with`, `Upload.abort` |
| Email | `Mail.from`, `Mail.to`, `Mail.headers`, `Mail.raw`, `Mail.raw_size_bytes`, `Mail.can_be_forwarded` |
| Others | `Log.info!`, `Log.warn!`, `Log.error!`, `Secret.reveal`, `SecretsStore.get`, `Version.metadata!`, `Tcp.connect_with`, `Io.map`, `Id64.from_i64`, `Id64.to_u64`, `Id64.to_i64`, `Native.Blake3.new!`/`update!`, `Native.Sha256.new!`/`update!`, `WebSocket.Message.json` |

## 4. Workers features that the platform does not have

| Feature | State | Where | Effect on a user |
| --- | --- | --- | --- |
| Workflow written in Roc (`WorkflowEntrypoint`, `step.do`) | Not possible: needs JS-to-Roc callbacks (AQ1) | API.md:835, MODULES.md:1864 | `Workflows` is a client only |
| Workflows `restart`, `createBatch`, instance `delete`/`subscribe`; `create_with!` options other than `id` | Not built | PLAN.md:2494 (OO4), MODULES.md:1886 | Use `Js` programs |
| `HTMLRewriter` | Not possible (AQ1) | API.md:835 | No streaming HTML rewrite |
| `blockConcurrencyWhile` in a handler, `transactionSync` | Not possible (AQ1); only `init!` | API.md:835, MODULES.md:1265 | No explicit DO transaction |
| KV-backed Durable Object classes | Refused | MODULES.md 7, js/index.js:41-52 | Move to SQLite classes |
| Images, Browser Rendering, mTLS, dispatch namespaces | No module | MODULES.md:1868 | `Js` only |
| Containers, Pipelines | Not mentioned | none | Not supported |
| `Ai` binary output, `returnRawResponse`, SSE parser for `stream!` | Not built | PLAN.md:2495 (OO5) | `Js` for image models |
| `Ai`, `Vectorize` result shapes | Stub tests only | PLAN.md:2496 (OO6) | Real results can differ |
| `TraceItem` `entrypoint`, `scriptVersion`, `cpuTime`, `wallTime`, `dispatchNamespace`, `truncated` | Not typed; adding later is a major change | MODULES.md:375, PLAN.md:2271 (QO4) | Tail Worker cannot read them |
| `Response.from_http`, `to_http!` | Not built | MODULES.md:687, PLAN.md:1489 | Convert by hand |
| Hyperdrive with a SQL driver | Raw `Tcp` and `config!` only | MODULES.md:1863 | App speaks the DB protocol |
| Not tested on the edge | `StartTls` (EP6), Ed25519, X25519, P-521 (Q3), `location_hint` (FO1), `can_be_forwarded` (QO3), `web_socket_error!`, socket limits, `binaryType` | PLAN.md:1790, :2134, :2270, :2650, :2805-2810 | Local results only |

Open points in PLAN.md that users can see:

- QO6 (PLAN.md:2272): a queue body that CBOR cannot write is retried as an empty body until the retry limit or the dead letter queue; the handler never sees it. Document in MODULES.md 6.
- O1 of 8b (PLAN.md:1616, :2793): without `enable_request_signal`, a local writer-stream task waits forever when the client leaves. The edge cancels the stream (EP3), and `sync` requires the flag.

## 5. Checks with no problem

| Check | Result |
| --- | --- |
| Code-block signatures vs platform/*.roc | Same, except API.md:342-357 (N3) |
| `Module.name` references in all docs | All exist, except removed or not-built names and N3, N4 |
| New 0.0.10 names in README "Changes" | All exist |
| `startApp` options in README vs `KNOWN` in test.mjs:292 | Same 22 options |
| `makeHandler` options vs MODULES.md 3 | Same |
| Binding kinds in js/bindings.js vs Wrangler keys | Same |
| README sync commands and flags vs cli.mjs | Agree |
| bundle.sh content check | js/ with test.mjs, test-entry.js and template/ is in the bundle |

## 6. Fixes (2026-11-11, branch cbor-0.5.0)

| # | State | What changed |
| --- | --- | --- |
| B1 | Done | The three headers have the same 0.5.0 URL. The tag 0.5.0 of roc-cbor is commit 29bb6dc, not 5366ccd: 29bb6dc is 0be9b12 (streams, `key_order`, `max_buffer`) plus a fuzz fix. The platform builds and tests with the URL. New `scripts/check-packages.sh` (step 0 of `scripts/bundle.sh`) and its test `scripts/check-packages-test.sh` (a local path, an `http://` URL and no `packages` block fail; a step of `bench/test-all.sh`). The docs say roc-cbor 0.5.0 in place of 5366ccd. |
| B2 | Done | `js/template/main.roc`: `/fetch` gets the constant `page_url`. `examples/hello/main.roc` keeps `/fetch?url=U` with a warning comment (`scripts/test_example.sh` needs it). |
| B3 | Ready | Title without "(not released)". At release time only the URL row and the status line change. |
| B4 | Done | `.github/release-notes.md`: roc-cbor 0.5.0, "Stored data: read before the deploy", "Known gaps". |
| B5 | Done | Nightly 2026-10-19 builds `test-helper/app` with roc-cbor 0.5.0: 0 errors, 0 warnings. `min_nightly` stays. |
| S1 to S4, S6 to S10, S12 to S14 | Done | Text only. S6: the walk-through needs the network, so the table says that it was checked with 0.0.1. |
| S5 | Not done | Talon 0.0.1 (the only Talon release) refuses a step table with `ok-exit` ("a table step needs the strings in and run, and no other key"). `roc-cfw init` writes the `[scripts]` table of `js/template/talon.toml` as it is, so the default would stop every script on Talon 0.0.1. Do it after a Talon release with R-RUN18. |
| S11 | Done | `sync` gives a note that names each `env.<name>`. |
| N1 to N16 | Done | N7, N8, N9, N13 with tests that failed before the fix (`bench/cli-test.mjs` 10a to 10g, `bench/trap-test.mjs` 1r, 1r2) and filtered revert entries (`bench/cli-reverts.mjs audit`, `bench/trap-reverts.mjs "audit N13"`). |
| N17 | Not done | Out of scope (user). |

`roc test platform/main.roc`: 260 is right. With the local path of roc-cbor (ebfb13f), `roc test` also ran the 160 `expect`s of the package (260 + 160 = 420). With the URL, the expects of a downloaded package do not run. No platform test was lost.
