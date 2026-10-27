# Doc fixes: probes

Check: `.cache/nightlies/$(cat compat/last-stack-first-nightly)/roc check --no-cache <file>`. Each probe has the platform as a path entry. Results on nightly 2026-10-19 (first run) and 2026-10-26 (pinned, run of 2026-10-27).

| Item | Probe | 2026-10-19 | 2026-10-26 |
| --- | --- | --- | --- |
| X5, `scheduled!` calls `s.no_retry!()`, no annotation | `x5_scheduled_no_annotation.roc` | Compiles | Compiles. No annotation is needed. |
| X5, `queue!` calls `batch.retry_all_with!(...)`, no annotation | `x5_queue_no_annotation.roc` | Compiles | Compiles. No annotation is needed. |
| X6, bare `?` on `key.metadata`, annotated function, error union with no `Missing` | `x6_bare_question_metadata.roc` | Type mismatch | Type mismatch (a normal type error: the union has no `Missing`) |
| X6, same, and the union has `Missing` | `x6_bare_question_with_missing.roc` | Type mismatch (the `[Missing]` is closed) | Compiles |
| X6, bare `?` on `key.metadata`, no annotation on the function | `x6_bare_question_no_annotation.roc` | Compiles | Compiles |
| X6, the form of the docs `(key.metadata ? \|_\| Missing).parse()` | `x6_mapped_question_metadata.roc` | Compiles | Compiles |
| X2, `req.json!()?` with no annotation, to `Response.from_json` | `x2_json_bad.roc` | not run | 1 error at the read: `encoder_for ... never resolved` |
| X2, the fix (`body : Ask`) | `x2_json_ok.roc` | not run | Compiles |
| X2, `db.all!` with no annotation, to `Response.from_json` | `x2_d1_bad.roc` | not run | 1 error at the read: `encoder_for ... never resolved` |
| X2, `db.all!` with no annotation, only `.len()` | `x2_d1_len_bad.roc` | not run | 2 errors: `parser_for ... never resolved` at the read, `to_str` at the use |
| X2, `db.first!` with no annotation, only `row.n.to_str()` | `x2_d1_field_bad.roc` | not run | 2 errors: `A where clause requires the parser_for method` with `{ n: a } where [a.to_str : a -> Str]`, `to_str` at the use |
| X2, the fix (annotated rows) | `x2_d1_ok.roc` | not run | Compiles |
| X2, `Memo` loader with no annotation that gives `res.json!()` | `x2_memo_bad.roc` | not run | Compiles (the `Memo(Config)` constant gives the type) |
| X2, annotated loader | `x2_memo_ok.roc` | not run | Compiles |
| X4, `.map(Got)` | no probe | A tag is not a function (FINDINGS-core C4). The text has `.map(\|r\| Got(r))`. | |
| D1 BLOB into `Cbor.Bytes` | no probe | `Cbor.Bytes` of roc-cbor 0.2.1 and later reads an array of integers 0 to 255 (`platform/Cbor.roc` `expect`, conformance `d1`). So the BLOB reads. | |
| 9, `Js` imports `Io` (to move `Io.new` and `Io.sync` under `Js`) | `i9_io_cycle/run.sh` (patch `js-imports-io.patch`) | not run | "import cycle detected" (2 errors), then each `Js.` name in `Io.roc` "does not exist" |
