# Doc fixes: probes

Check: `.cache/nightlies/$(cat compat/last-stack-first-nightly)/roc check --no-cache <file>` (nightly 2026-10-19). Each probe has the platform as a path entry.

| Item | Probe | Result |
| --- | --- | --- |
| X5, `scheduled!` calls `s.no_retry!()`, no annotation | `x5_scheduled_no_annotation.roc` | Compiles. No annotation is needed. |
| X5, `queue!` calls `batch.retry_all_with!(...)`, no annotation | `x5_queue_no_annotation.roc` | Compiles. No annotation is needed. |
| X6, bare `?` on `key.metadata`, annotated function, larger error union | `x6_bare_question_metadata.roc` | Type mismatch (the `[Missing]` is closed). |
| X6, same, and the union has `Missing` | `x6_bare_question_with_missing.roc` | Type mismatch (the same reason). |
| X6, bare `?` on `key.metadata`, no annotation on the function | `x6_bare_question_no_annotation.roc` | Compiles. |
| X6, the form of the docs `(key.metadata ? \|_\| Missing).parse()` | `x6_mapped_question_metadata.roc` | Compiles. |
| X4, `.map(Got)` | no probe | A tag is not a function (FINDINGS-core C4). The text now has `.map(\|r\| Got(r))`. |
| D1 BLOB into `Cbor.Bytes` | no probe | `Cbor.Bytes` of roc-cbor 0.2.1 reads an array of integers 0 to 255 (`src/Cbor.roc:21`, `platform/Cbor.roc:120` `expect`). So the BLOB reads. |
