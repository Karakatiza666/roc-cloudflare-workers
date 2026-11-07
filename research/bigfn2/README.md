# The 243 KB function (func 369) in worker/app.wasm

> Correction (2026-11-07, filed as roc-lang/roc#12905; details in talon/research/sortcopy/README.md): the copy comes from each new element type (each specialization), not from each call site. A second call with the same type and comparator adds about 0.3 KB; a new tuple type adds about 86 KB (--opt=speed), a new record type with the same layout about 20 KB. The registry's 12 sites sort 12 different row types, so the result for it is the same. Still there on nightly-2026-11-07-ad3a5d2.


## Result

| Item | Finding |
| --- | --- |
| What func 369 is | The code of one `List.sort_with` call: `rows.sort_with(by_repo)` in worker/ReconcileCron.roc:65 (element: the 10-field `Claimed` row). Not platform code. It has no string in its body, 127,876 instructions, and its callers are the reconcile cron function (func 333) and its own sort helpers (363 to 366). |
| Cause | The compiler makes a full copy of its sort (about 140 to 250 KB) for each call site: each element type and each comparator is a new specialization (repro/, table 2). The registry has 11 sort sites: 3 in packages/records (Artifact.roc:61, 62; Code.roc:112) and 8 in worker/. They make about 1.9 MB of the 5.17 MB code section. |
| Fix | A stable merge sort in Roc (`Sorted.sort_with`, 36 lines) for all 11 sites. Each site then costs a few KB. |
| Compiler issue | Yes: draft in upstream-issue.md (not posted). |

## 1. Evidence

| Variant (dir in variants/) | Change | wasm file | Code section | Largest function |
| --- | --- | --- | --- | --- |
| base | none (byte-identical to worker/app.wasm) | 5,260,039 | 5,169,169 | 242,991 (the sort) |
| nosort1 | the sort of ReconcileCron removed | 4,762,225 | 4,671,402 | 176,616 (roc_event) |
| keyidx | ReconcileCron sorts (I64, index) pairs, not the rows | 4,816,392 | 4,725,554 | 176,616 |
| msort | 8 sites in worker/ use `Sorted.sort_with` | 4,111,536 | 4,020,747 | 176,616 |
| m2 | all 11 sites (also records) use `Sorted.sort_with` | 3,393,205 | 3,302,597 | 176,616 (the next: 70,730) |

One sort of the 100-byte row is 499 KB of code in the file (func 369, 363 to 366 and 4 more functions). The (I64, index) pair is 54 KB.

Next 5 largest functions of base (wasmscan.mjs `top`): all but roc_event have no string, so they are sorts too.

| Func | Bytes | What |
| --- | --- | --- |
| 186 | 176,616 | `roc_event` (the entry, fetch path) |
| 761 | 167,086 | a sort (in the ingest path: Artifact.encode, records) |
| 1037 | 125,699 | a sort (the same family) |
| 975 | 123,868 | a sort |
| 774 | 115,812 | a sort |

## 2. Native repro (repro/, `repro/measure.sh`, text bytes, nightly-2026-10-31-f7bef6b)

| Program | Text bytes |
| --- | --- |
| no sort | 13,856 |
| `sort_with`, U64 | 187,780 |
| `sort_with`, (I64, U64) | 156,056 |
| `sort_with`, record with 6 Str | 242,736 |
| `sort_by`, the same record | 249,232 |

## 3. V8 (fntime.sh, this machine, noisy)

| File | Largest function | Liftoff | Machine code |
| --- | --- | --- | --- |
| base | 369 (243 KB) | 6.0 to 9.4 ms | 628 KB |
| m2 | 186 (177 KB) | 2.2 to 4.8 ms | 357 KB |

## 4. Files

| File | Use |
| --- | --- |
| sort-fix.diff | the proposal, against talon/worker and talon/packages/records (not applied there) |
| sorted-test/ | 6 `expect`s: same result as `List.sort_with`, stable, 200 and 501 items. 3 fail when `Before` is changed to `Before \| Same` in `merge` (checked). |
| wasmscan.mjs | the bigfn tool, plus modes `top N`, `anc <funcs>`, `consts` |
