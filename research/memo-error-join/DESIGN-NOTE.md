# Memo constant and the error join (nightly 2026-10-26)

Verdict: new behavior, by design. It is not a regression. Do not file an issue.

## 1. What changed

| Item | Value |
| --- | --- |
| Last good nightly | `nightly-2026-10-19-601b54c` |
| First bad nightly | `nightly-2026-10-21-5349569` (also `nightly-2026-10-26-3c0fffe`) |
| Compiler change | roc-lang/roc PR #12330 "Join tag rows where values flow instead of converting them" (merge `534956997e`, the commit of the 10-21 nightly) |
| Commit with the rule | `61c0f6d8af` "Share one row per module for top-level values, and join rows by occurrence" |
| Related commits | `9a7c90e9da` (row joins replace conversions), `4b6b610e89` (`?` composes a closed row by its heads only) |
| Design text | roc `design.md`, "Value Rows: Uses Share One Row" and "Row Joins" (still in `3c0fffe`) |

The PR text says: "An unannotated top-level value now has one row shared by every
use in its module, closed when the module finishes checking, and importers see
exactly that closed row; an annotated top-level value keeps the row it was written
with." The design text lists the cost as accepted: "an importer cannot widen an
imported value. An importer that needs a wider union rebuilds the tag or asks for
the annotation it needs."

Reason (design.md): a tag union is no longer converted at run time. A value has
one representation, so all its uses must agree on one row. The old rule (a
widening copy per use) needed a conversion at each read.

## 2. The rule now

| Binding | Row of its tags |
| --- | --- |
| Function (`c = \|\| ...`) | Generalized. Each call gets a fresh open row. Each caller widens freely. |
| Top-level value, same module | One row for all uses in the module. Uses widen it together, then it closes when the module is checked. |
| Top-level value, imported | The closed row of its module. No importer can widen it. |
| Annotated value | The rows of the annotation, closed as written. |

A `?` on a closed error row adds the head tags to the function result
(`4b6b610e89`). It does not widen a nested payload. So a flat closed row still
joins, but a closed `Infra([...])` payload must be equal to the `Infra` payload of
the caller.

## 3. Minimal repro (`min/`)

`min/Lib.roc`:

```roc
Lib := [].{
	c : Try({}, _)
	c = Err(Inner(A))
}
```

`min/main.roc`:

```roc
import Lib

f : Bool -> Try({}, [Inner([A, B])])
f = |b| {
	Lib.c?
	if b Err(Inner(B)) else Ok({})
}

main! = |_args| Ok({})
```

10-19: `No errors found`. 10-26:

```
── ✗ type mismatch ──── main.roc:5:2
This ? may return early with a type that doesn't match the function body.
    Lib.c?
If this Try is an Err, then the ? after it immediately returns an Err whose
payload has this type:
    [Inner([A])]
... but this function's return type is:
    Try({}, [Inner([A, B])])
```

The auction example before commit 32a0a8c (`auction-old/`, `roc check web.roc`)
gives the same error 3 times on 10-21 and 10-26 (`Gavel.config.get!()?`,
`Gavel.tables.get!()?`), and no error on 10-19. The probe
`research/plugin-probes/v2/s_memo_const.roc` passes on all 3 nightlies: its
`Memo` constants are in the same module as their only use.

## 4. Probe matrix (`./run.sh`)

| Probe | Shape | 10-19 | 10-26 |
| --- | --- | --- | --- |
| `min`, `variants/nested_const` | imported constant, nested `Inner([A])`, caller `Inner([A, B])` | ok | error |
| `variants/nested_unannotated_f` | same, caller result inferred | ok | error |
| `variants/nested_annot` | same, constant annotated `[Inner([A])]` | ok | error |
| `variants/flat_const` | imported constant, flat `[A]`, caller `[A, B]` | ok | ok |
| `variants/nested_fn` | imported function `c = \|\| ...`, nested | ok | ok |
| `variants/same_module` | constant in the caller module, one use | ok | ok |
| `variants/same_module_two_uses` | constant in the caller module, uses `Inner([A, B])` and `Inner([A, C])` | ok | error |
| `variants/nested_annot_full` | imported constant annotated with the full caller row `[Inner([A, B])]` | ok | ok |
| `variants/current_stored_loader` | the `Memo(a, e)` shape (stored `load!`), 2 callers with other `Infra` payloads | ok | 2 errors |
| `variants/option3_loader_at_get` | `Memo(a)`, `get!` takes the loader, same 2 callers | ok | ok |

Note: `MODULES.md` (line 1226) says a `Memo` "used in one function only" can stay
a constant. That is true only in the module that defines it. An imported `Memo`
constant fails at one use too, when the `Infra` payload of the caller has another
tag (`nested_const`).

## 5. Options for the platform

The cause is the type of the constant: `Memo(a, e)` holds `load!`, so the error
row `e` is part of the value. Each option removes `e` from the constant, or pins
it.

| | Option | Change | Good | Bad |
| --- | --- | --- | --- | --- |
| 1 | Memo is a function (now) | No API change. Guidance: `config : () -> Memo(C, _)`, call `config().get!()` | Works on 10-19 and 10-26, for all callers. Already in `Gavel.roc` and `MODULES.md` 9. | The workaround stays. A constant compiles in some places and not in others, so users find the rule by an error far from the cause. The text "it does nothing until `get!`" (WR1) is less clear. |
| 2 | Pin the row by annotation | No API change. Guidance: annotate the constant with the one error type of the app, `config : Memo(C, Gavel.AppErr)`, and give each caller the same `Infra(Gavel.Faults)` | Stays a constant (`nested_annot_full`). | 10-19 refuses it (PLAN.md, 2026-10-26 status). Each caller must have the exact same nested payload, so all callers carry all tags of `Faults` (larger wasm, MC9). One annotation that does not agree gives the error again. |
| 3 | Loader at `get!` | `Memo(a)` has no error parameter. `Memo.new(name, { max_age_ms })`. `get! : Memo(a), (() => Try(a, e)) => Try(a, e)`, call `Gavel.config.get!(Gavel.load_config!)` | The constant has no tag row, so each call takes the open row of the loader function, and all callers join (`option3_loader_at_get`, 10-19 and 10-26). It is the same pattern as `cell.get_or!(default)`: the fallback is at the call. `Memo` stays a constant (WR1, MC6). | Breaking API change (0.0.3). The loader is named at each call. Two calls can give different loaders for one name (one pin). The type `a` is still one type, so the data stays safe, only the load can differ. |

## 6. Recommendation

Option 3 for the next API change, with option 1 as the guidance until then.

- Option 3 removes the cause: no value of the platform holds an error row. The
  compiler rule (2) then cannot apply to `Memo`. It also removes the trap for
  other platform values that store a fallible function (check `Kv.Cell`,
  `Object.Cell`, `Rpc` values: a constant whose type has an error row has the
  same rule).
- Until option 3: keep option 1, and change the text of `MODULES.md` 9 (line
  1217 to 1226) to the precise rule: "A top-level value has one row of tags. In
  its module, all uses share it; in an importer, it is closed. A nested closed
  payload such as `Infra([...])` does not widen at `?`. Use a function for a
  `Memo` that another module uses."
- Option 2 is not recommended: it fails on 10-19 and it makes each caller carry
  the full `Faults` union.

## 7. Files

| Path | Content |
| --- | --- |
| `env.sh` | Paths of the nightlies 10-19, 10-21, 10-26 |
| `run.sh` | Checks `min/` and `variants/*` with 10-19 and 10-26 |
| `min/` | The minimal repro |
| `variants/` | The probes of section 4 |
| `auction-old/` | `examples/auction` at `32a0a8c^` (platform path fixed), the original failure |
| `s_memo_const.roc`, `s_memo_fn.roc` | Copies of the v2 probes (pass on all 3 nightlies) |

## 8. After option 3 (platform 0.0.2, 2026-10-27)

Option 3 is in the platform (`platform/Memo.roc`). `platform-probes/consts/` checks each platform constant that a
user keeps at the top of a module, used from another module by a caller with an inferred error type and by a
caller with a wider annotated error type, each joined with a `D1` call.

| Constant | 10-19 | 10-26 |
| --- | --- | --- |
| `Memo(a)` (imported, and 2 uses in one module) | ok | ok |
| `Kv.Cell(a)` (`get!`, `get_or!`) | ok | ok |
| `Queue(a)`, `Workflows(a)`, `Object.Cell(a)`, `D1`, `Service(iface)` | ok | ok |
| `Rpc` method annotated with its error type | ok | ok |
| `Io(a, e)` value (`cell.get_or("d")`) | ok | error at the `?` (2) |

`platform-probes/rpc_infer/`: an `Rpc` method with no annotation is "missing method" on both nightlies. The
annotation is required (the doc of `Rpc.Iface.method`, `platform/Rpc.roc:134`), so it is not part of this change.
