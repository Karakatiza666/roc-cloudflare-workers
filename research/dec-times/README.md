# Dec multiply: `times_saturated` bug

Found 2026-10-22 in the auction example (`examples/auction/ledger.roc`). `Dec` has no `times_try`.

| Item | Value |
| --- | --- |
| Issue | https://github.com/roc-lang/roc/issues/12516 |
| Bug | `Dec.times_saturated(a, b)` crashes with "Decimal division overflow!" when `b` is below 1 |
| Nightlies | 2026-10-12-2664a27, 2026-10-19-601b54c, 2026-10-21-5349569: the same |
| Workaround | `convert` in `ledger.roc`: an F64 estimate above 1e20 means out of `U64` range, else the normal `Dec` multiply |

## Files

| File | Use |
| --- | --- |
| `t.roc` | Minimal repro. `roc test t.roc` |
| `echo.roc` | The same as an app (a crash at compile time). `roc echo.roc` |
| `ops.roc` | The other `Dec` ops. `roc test ops.roc`: 27 pass, 2 fail (both `times_saturated`, marked BUG) |
| `ISSUE.md` | The body of the issue |

## Other Dec ops (checked with `ops.roc`)

| Op | Result |
| --- | --- |
| `plus_saturated`, `minus_saturated` | correct, also at `Dec.highest` and `Dec.lowest` |
| `plus_try`, `minus_try` | correct (`Err(Overflow)` at the edge) |
| `round_try`, `floor_try`, `ceiling_try`, `round_to_try` | correct (`Err(Overflow)` at the edge) |
| `round_to_u64_try`, `to_u64_try` | correct (`Err(OutOfRange)` for a negative or too large value) |
| `sqrt_try` | correct |
| `times` | correct, crashes above `Dec.highest` as documented |
| `times_saturated` | crash for a second argument below 1. Correct for a second argument of 1 or more, and at the edge |
| `times_try` | does not exist |
