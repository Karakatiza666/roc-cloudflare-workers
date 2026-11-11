# D1 integers of 2^53 or more: is a helper good UX? (probe)

Question (`research/design_issues_tmp.md` row 2b, `MODULES.md` 5.1 "Integers in rows" and "Ids: Id64"): does a helper for large D1 integers give a better user experience than the CAST rule of today? The user asked for a helper only "if it provides good UX (automatic literal derivation in binary ops, etc.)".

Answer: no. Do not add a number-like type or a SQL helper. Keep `I64` with `CAST(x AS TEXT)`, keep `Id64` for ids, and add the recipes of the table "Recipe" to `MODULES.md`.

Run (from the submodule root): `research/d1-int-helper/run.sh`. The probes ran against platform HEAD `6c0f7a0` in a temporary worktree (`PF_ROOT=research/d1-int-helper/wt`), with the pinned nightly `nightly-2026-10-26-3c0fffe` and Miniflare 5.20261012.0-beta.

## Files

| File | Content | Result |
| --- | --- | --- |
| `js/exact.mjs`, `js/exact.out.txt` | Local D1: `all()`, `raw()`, `first()`, `first(col)`, `meta.last_row_id`, SQL text tricks, the internal `fetcher` of the binding | Each number API rounds 2^53 + 1 to 2^53. Only text in SQL is exact. |
| `roc/DbInt.roc` | Option C: a number-like type (`from_numeral`, operator methods, strict text read, CBOR integer write) | Compiles, 20 methods by hand |
| `roc/SqlInt.roc` | Option B: `col("p.id")` gives `CAST(p.id AS TEXT) AS id` | 4 tests pass |
| `roc/app.roc`, `app.out.txt` | Row reads of the CBOR that `pf.pack` sends, with the options of `SqlRules.typed` (`int_from_text`), for `I64`, `DbInt`, `F64`, `Dec`, `Str` | 16 tests pass (207 with the platform tests) |
| `roc/usage.roc` | The user code of A, B and C: read, write, new id, compare, add, through `D1.first!` and `D1.run!` | `roc check`: no errors |
| `must-not-compile.sh`, `must-not-compile.out.txt` | Compile matrix: 21 cases of `DbInt` and `I64` | All 21 as expected |

Mutation check: a `DbInt` parser that also reads a CBOR integer makes 1 test of `app.roc` fail (line 57, "no CAST, a small id").

## The JS side (probe J)

| Path | Result for 2^53 + 1 | Evidence |
| --- | --- | --- |
| `all()`, `raw()`, `first()`, `first('id')` | 2^53 (rounded) | `js/exact.out.txt` |
| `meta.last_row_id` | 2^53 (rounded) | same |
| A `BigInt` option | None. A `BigInt` parameter is `D1_TYPE_ERROR` (workerd `D1PreparedStatement.bind`). `raw()` takes only `columnNames`. | `research/d1-shapes/README.md`, workerd source (`strings` of the binary) |
| Internal `env.DB.fetcher` (`/query`, raw response text) | 2^53: the D1 server already sends the rounded number | `fetcher_text` in `js/exact.out.txt` |
| New JSRPC path (`fetcher.query`, flag `d1BindingJsrpc` in workerd) | Not testable locally. Not public API. | workerd source |
| `CAST(id AS TEXT)`, `printf('%d', id)`, `id \|\| ''` | `"9007199254740993"` (exact) | `js/exact.out.txt` |
| `json_object('id', id)` | `{"id":9007199254740993}` as text (exact, but a JSON parse rounds it again) | same |
| `INSERT ... RETURNING CAST(id AS TEXT) AS id` | `"9007199254740995"` (exact new id) | same |
| `WHERE id = ?` with the text parameter | match (1 row) | same |
| `CAST(id + 1 AS TEXT)` | `"9007199254740994"` (exact add in SQL) | same |
| `CAST(v AS TEXT)` of a column with no type (REAL stored) | `"5.0"`: not an integer text, so the typed read gives `BadData` | same |

So the data is rounded before Roc sees it. No Roc type can repair it. Each option must still put a CAST in the SQL.

## The Roc side: a number-like type (probe C)

| Expression (`x : DbInt`, `n : I64`) | Result | For `I64` |
| --- | --- | --- |
| `x + 1`, `x - 1`, `x * 2`, `x // 2`, `x % 2`, `-x` | compiles | compiles |
| `x == 5`, `5 == x`, `x > 0`, `0 < x` | compiles | compiles |
| `1 + x`, `2 * x + 1` (literal on the left) | MISSING METHOD ("number's type never resolved") | compiles |
| `y : DbInt` then `y = 1 + x` | compiles | compiles |
| `7.DbInt + x` | compiles | `7.I64` |
| a literal above 2^63 - 1 | compile error (`from_numeral` rejects it) | same |
| `x + n`, `x == n` | TYPE MISMATCH | n/a |
| `x.abs()`, `x.plus_try(1)`, `x..<x` | MISSING METHOD (each needs a wrapper) | compiles |
| `Encoding.Json.to_str({ id: x })` | `{"id":9007199254740993}`: a browser rounds it, no error | same |

The compiler allows a custom number type (`from_numeral`, `plus`, `is_lt` and the other operator methods). A literal works on the right side and in a compare on the left. It fails on the left of an arithmetic operator unless the result has an annotation.

## Options

| | A: no helper, doc only (today) | B: SQL helper `SqlInt.col` | C: number-like type `DbInt` | D: platform does the cast |
| --- | --- | --- | --- | --- |
| Read | `SELECT CAST(id AS TEXT) AS id` into `id : I64` | `SELECT ${SqlInt.col("id")}` into `id : I64` | `SELECT CAST(id AS TEXT) AS id` into `id : DbInt` | Not possible: no exact JS path, and the platform cannot see the field names of the row type, or parse the SQL of the user |
| Write | `[id]` (an `I64` of 2^53 or more binds as text) | same as A | `[x]` (same bind) | n/a |
| New id | `RETURNING CAST(id AS TEXT) AS id` | `RETURNING ${SqlInt.col("id")}` | same as A | n/a |
| Compare | `row.id == id`, `row.id > 0` | same as A | `row.id == key`, `row.id > 0` | n/a |
| Add | `row.id + 1`, `1 + row.id` | same as A | `row.id + 1`; `1 + row.id` needs an annotation | n/a |
| No CAST, id below 2^53 | Ok (exact) | same as A | `BadData("column id: the value does not fit the type")` at the first test | n/a |
| No CAST, id of 2^53 or more | `BadData(... read it with CAST(id AS TEXT) ...)` | same as A | `BadData` | n/a |
| Silent loss | `F64` or `Dec` field (`app.roc` 110, 117); `rows!` `Real(F64)`; a text param compared with no column (K10) | same as A, plus a bad alias for an expression (`SqlInt.col("a.id + 1")` gives `... AS id + 1`) | same as A, plus JSON writes a number that a browser rounds | n/a |
| Cost | Doc lines | 1 small function, hides SQL, no gain in safety | A second integer type: 20 methods to keep, no `I64` API (`abs`, `_try`, ranges, `to_*`), `.to_i64()` at each border with other code, a new error text | n/a |
| Evidence | `app.roc` 80 to 106, `conformance/checks/d1.mjs` 97 to 119 (end to end) | `SqlInt.roc`, `usage.roc` | `DbInt.roc`, `app.roc` 27 to 76 and 131 to 146, `must-not-compile.out.txt` | `js/exact.out.txt` |

The one gain of C: a SELECT with no CAST fails at the first test, not at the first value of 2^53 or more. For random 64-bit ids that value comes at once, and `Id64` already covers ids. For a counter or a sum, 2^53 is far away. That gain does not pay for a second integer type.

## Recipe (proposal for `MODULES.md` 5.1)

| Task | SQL | Roc |
| --- | --- | --- |
| Read | `SELECT CAST(id AS TEXT) AS id, name FROM t` | `{ id : I64, name : Str }` (or `Id64` for an id) |
| New id | `INSERT ... RETURNING CAST(id AS TEXT) AS id` | `db.first!` into `{ id : I64 }`, not `Info.last_row_id` |
| Write | `INSERT INTO t (id) VALUES (?)` | `[id]` |
| Compare in SQL | `WHERE id = ?` (a column on one side) | `[id]` |
| Add in SQL | `SELECT CAST(id + 1 AS TEXT) AS next` | `{ next : I64 }` |
| Compare, add in Roc | none | `row.id > 0`, `row.id + 1` (plain `I64`) |
| Do not | read into `F64` or `Dec`; use `rows!` for such a column; store integers in a column with no type | |

## Open points (not in scope)

| Point | Note |
| --- | --- |
| An `F64` or `Dec` field reads a rounded integer with no error | A platform rule could refuse it, but a REAL column also gives an f64 with no fraction. Needs a human decision. |
| D1 JSRPC (`d1BindingJsrpc`) | If D1 later sends 64-bit integers as `BigInt` on this path, check again. |
