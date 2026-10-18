# Probe: opaque `Request` and `Response` (step 8h wave C, issue 7)

`Request`, `Response`, `Worker.Scheduled`, `Worker.TraceItem`, `Queue.Batch`, `Queue.Message` and `Email.Mail` are opaque
(`::`). An app reads them with methods. Run from the repo root:

```sh
ROC=$(bench/get-roc.sh); ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache $ROC check --no-cache research/c-sweep-probe/<file>.roc
```

Results (nightly of `bench/get-roc.sh`, 2026-10-18):

| File | What it does | Result |
| --- | --- | --- |
| `field_read.roc` | unannotated `fetch! = \|req\|`, reads `req.method` | 2 errors: `segments` is missing on `{ method: _val, .. }` (the read made `req` a record), and `Worker.new` gets the wrong type. Before this step the result was the same. A field read of an opaque type cannot compile. |
| `method_read.roc` | the same `fetch!` with `req.method()`, `req.url()`; unannotated `scheduled!` with `s.no_retry!()` and `s.cron()`, `queue!` with `batch.messages()` | No errors |
| `wrong_use.roc` | unannotated `fetch!`, `req.method().concat(...)` (a `Method` is not a `Str`) | 1 error, at `.concat`: "The value's type ... is: Method" |
| `typo_use.roc` | unannotated `fetch!`, `req.path()` (no such method) | 1 error, at `.path`: "The value's type ... is: Request" |
| `annotated_field.roc` | `fetch! : Request => ...`, reads `req.url` | 1 error, at `req.url`: "It is: Request. But I need a record with a url field." |

So with the methods, the type of an unannotated handler comes from `Worker.new`, and an error is at the use.
A field read still gives the far error of `field_read.roc` when the handler has no annotation: the compiler makes a
record type from the read before it sees `Worker.new`. The first error of that file is at the read, but it names a
method (`segments`), not the field.

`formats.roc` (issue 8, `roc test`, not `roc check`): round trips in Roc for the table "Formats of typed data" of
`MODULES.md` 1. All 7 pass: an integer above 2^53 in CBOR and in JSON, an `F64` NaN in CBOR, `Json.to_str_try` of a NaN
is an error, a `Dec` in JSON, an `Id64` in CBOR, a `List(U8)` and a `Cbor.Bytes` in CBOR. A `Dec` in CBOR does not
compile: roc-cbor 0.1.0 has no `encode_dec` and no `parse_dec`.
