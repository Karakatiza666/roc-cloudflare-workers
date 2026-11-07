# DRAFT, not posted: each `List.sort_with` call site adds 140 to 230 KB of machine code

Nightly: nightly-2026-10-31-f7bef6b (x86-64 Linux and wasm32). `--opt=speed`.

A headerless program with one `List.sort_with` of a `List(U64)` grows from 13.9 KB to 187.8 KB of text.
Each other call site with another element type or another comparator adds more code (a copy of the whole sort for each specialization).

| Program (repro/*.roc) | Element | Text bytes |
| --- | --- | --- |
| nosort.roc | (no sort) | 13,856 |
| u64.roc | U64, `sort_with` | 187,780 |
| pair.roc | (I64, U64), `sort_with` | 156,056 |
| main.roc | record of 6 Str and 2 U64 (80 bytes in a 64-bit build), `sort_with` | 242,736 |
| sortby.roc | the same record, `sort_by` | 249,232 |

In a real wasm32 Worker (Talon registry) the 8 call sites of `sort_with` make about 1 MB of the 4.7 MB code section.
The largest function of the file (243 KB, V8 TurboFan about 180 ms) is one such sort.

Expected: a sort for a few KB of code (or one shared copy that takes the element size and the comparator as data), at least with `--opt=size`.
Workaround: a 30-line merge sort in Roc is a few KB for each call site.
