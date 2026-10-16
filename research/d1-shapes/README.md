# Shapes of local D1 (PLAN.md 8c, D1 wave, 2026-10-16)

`shapes.mjs` prints what the D1 binding of Miniflare (5.20261012.0-beta) gives, for the programs of `platform/D1.roc`. `out.txt` is its output.

| Call | Shape |
| --- | --- |
| `run()` | `{ success, meta, results: [] }`. `meta` has `duration`, `changes`, `last_row_id`, `rows_read`, `rows_written`, `changed_db`, `size_after`, `served_by`, `served_by_primary`, `total_attempts`, `timings`. |
| `all()` | `{ success, meta, results }`, `results` an array of plain objects |
| `raw({ columnNames: true })` | An array: the column names, then one array for each row. No row: only the names. |
| A blob in `all()` and `raw()` | An `Array` of numbers, not an `ArrayBuffer` |
| `first()` of no row | `null` |
| `batch()` | An array of plain objects, one for each statement, each as `all()` |
| `withSession("first-primary")` | A `D1DatabaseSession`. `getBookmark()` is `null` before the first query, then a text. |
| `withSession("bad bookmark")` | No throw, and a query on it does not throw (the workerd source has `D1_SESSION_ERROR`) |
| A `BigInt` parameter | `Error: D1_TYPE_ERROR: Type 'bigint' not supported for value '1152921504606846976'` |
| `exec("SELEC 1")` | `Error: D1_EXEC_ERROR: Error in line 1: SELEC 1: near "SELEC": syntax error at offset 0: SQLITE_ERROR` |

Run: `node research/d1-shapes/shapes.mjs`.
