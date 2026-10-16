# D1 feedback probes (2026-10-16)

Evidence for MODULES.md 5.1 ("Integers in rows", "Constraint kinds") and PLAN.md 8c wave 1 O5.

| File | What it shows | Run |
|---|---|---|
| `probe.mjs` | Integers near 2^53 and negative 64-bit ids in D1 and in Durable Object SQL; the error objects of PK, UNIQUE, FK, CHECK, NOT NULL, DATATYPE and trigger RAISE failures | `node probe.mjs` (Miniflare of the global wrangler) |
| `out.txt` | The output of `probe.mjs` (Miniflare 5.20261012.0-beta) | |
| `meta.mjs` | `meta.last_row_id` after an insert of a 64-bit rowid: it is rounded | `node meta.mjs` |
| `errpos.roc` | Today `roc-cbor` reads an f64 2^53 into an `I64` field with no error | `roc test errpos.roc` with `pkg` set to a copy of `roc-cbor` |
| `options.roc` | Tests of the proposed `parse_with`, `int_from_text` and `path_at` | same, on a copy with `roc-cbor-proposal.diff` applied |
| `roc-cbor-proposal.diff` | The prototype of the `roc-cbor` change (67 of 67 tests pass) | `git apply` in a `roc-cbor` checkout |
