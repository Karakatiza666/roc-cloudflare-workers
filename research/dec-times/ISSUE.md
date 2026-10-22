`Dec.times_saturated(a, b)` crashes with "Decimal division overflow!" when `b` is below 1 (for example `1.0` times `0.5`). The same inputs work with `Dec.times`. The call is not an overflow case.

Found in a downstream platform (a Cloudflare Workers platform for Roc) while I looked for a checked `Dec` multiply: `Dec` has no `times_try`.

Environment: Linux x86_64, `nightly-2026-10-12-2664a27`, `nightly-2026-10-19-601b54c` and `nightly-2026-10-21-5349569` (all three the same).

Repro, `t.roc` (no platform):

```roc
expect Dec.times_saturated(1.0, 0.5) == 0.5
```

Command: `roc test t.roc`

Output:

```
Roc application crashed with this message:

	Decimal division overflow!


── ✗ fail ──────────────────────────────────────────────────────────── t.roc:3:1

expect Dec.times_saturated(1.0, 0.5) == 0.5
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Ran 1 tests in 11.7 ms. (cached):
    0 passed
    1 failed
    0 compiler errors
```

As an app (`roc echo.roc`), the crash is at compile time, in the module Builtin (line 16372, column 29):

```roc
main! = |_args| {
	echo!(Dec.times_saturated(1.0, 0.5).to_str())
	Ok({})
}
```

```
── ✗ compile time crash ─────────────────────────────────────────── echo.roc:2:8

This definition crashed during compile-time evaluation.

The crash happened in the module Builtin (line 16372, column 29), with this
message:

    Decimal division overflow!
```

Other inputs:

| Call | Result |
| --- | --- |
| `Dec.times_saturated(1.0, 0.5)`, `(0.5, 0.5)`, `(1.0, 0.9)`, `(1000.0, 0.5)`, `(Dec.highest, 0.5)` | crash |
| `Dec.times_saturated(0.5, 1.0)`, `(0.5, 2.0)`, `(1.0, 1.0)`, `(1000.0, 1.5)`, `(2.0, 3.0)`, `(3.0, 0.0)` | correct |
| `Dec.times_saturated(Dec.highest, 1.5)`, `(Dec.highest, 2.0)`, `(Dec.lowest, 2.0)` | `Dec.highest` or `Dec.lowest`, correct |

So the crash depends on the second argument being a fraction below 1. Expected: `0.5`.
