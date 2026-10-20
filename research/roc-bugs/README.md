# Roc compiler bugs

Minimal repros of the two compiler bugs that `MODULES.md` 15 names. `./run.sh <roc> [<roc> ...]` runs each case and marks with `BUG` each case where the compiler does not do what the Roc docs say.

| Nightly | Bug 1 | Bug 2 |
| --- | --- | --- |
| `nightly-2026-10-09-258ab27` | Yes | Yes |
| `nightly-2026-10-12-2664a27` | Yes | Yes |
| `nightly-2026-10-14-38a3029` (latest on 2026-10-15) | Yes | Yes |
| `nightly-2026-10-19-601b54c` (checked on 2026-10-20) | No | No |

Issues: bug 1 is roc-lang/roc#12309, bug 2 is roc-lang/roc#12310 (filed on 2026-10-15; no older issue matched).

## Bug 1: a nominal type with no opt in encodes in a record field (#12309)

`docs/langref/parsers.md` ("Nominal Types"): a nominal type is not parseable or encodable until it declares `parser_for : _` and `encoder_for : _`. The compiler checks this for a bare value. It does not check it when the value is inside a record, a tuple or a tag, if the backing type is a builtin (`Str`, `U32`). The encoder then writes the backing value, so an opaque type leaks its hidden data.

`opaque-codec/repro.roc`:

```roc
Local :: Str.{
	from_str : Str -> Local
	from_str = |s| Local.(s)
}

main! = |_args| {
	echo!(Json.to_str({ token: Local.from_str("hunter2") }))
	Ok({})
}
```

Expected: "missing method encoder_for", as for `Json.to_str(Local.from_str("hunter2"))`. Got: it compiles and prints `{"token":"hunter2"}`.

| Case (`opaque-codec/`) | Value | Result |
| --- | --- | --- |
| `repro.roc` | `{ token: Local }`, type in the same file | BUG: `{"token":"hunter2"}` |
| `field.roc` | `{ token: Secret }`, `Secret :: Str` in a type module | BUG: `{"token":"hunter2"}` |
| `field_Id.roc` | `{ id: Id }`, `Id :: U32` | BUG: `{"id":7}` |
| `field_list.roc` | `{ tokens: List(Secret) }` | BUG: `{"tokens":["hunter2"]}` |
| `tuple.roc` | `(Secret, U64)` | BUG: `["hunter2",1]` |
| `tag.roc` | `[Token(Secret)]` | BUG: `{"Token":"hunter2"}` |
| `nominal_field.roc` | `{ name: Name }`, `Name := Str` (nominal, not opaque) | BUG: `{"name":"x"}` |
| `bare.roc` | `Secret` | ok: missing method |
| `list.roc` | `List(Secret)` | ok: missing method |
| `parse_field.roc` | parse into `{ token : Secret }` | ok: missing method |
| `parse_tuple.roc` | parse into `(Secret, U64)` | ok: missing method |
| `field_record_backing.roc` | `{ token: Token }`, `Token :: { text : Str }` | ok: missing method |

The backing type decides the result. `opaque-codec/backings/` has one file for each backing (`gen.sh` makes them): `W :: <backing>`, encoded as `{ v: W.(...) }` (field) and as `W.(...)` (bare).

| Backing of `W` | Field | Bare |
| --- | --- | --- |
| `Str`, `U8`, `U64`, `I64`, `Dec` | BUG: writes the value | ok: missing method |
| `F64` | BUG with `to_str_try` (`f64_field_try.roc`). With `to_str`, the error is a type mismatch on the error row of `encode_f64`, so the checker also took `W` as an `F64`. | ok: missing method |
| `Bool`, as `W :: Bool` or `W := Bool` | BUG: SIGSEGV in the compiler, in "post-check monotype". A plain `Bool` in the same record encodes (`plain_bool_field.roc`). | ok: missing method |
| `[A, B(U64)]`, `[A, B]`, `Try(U64, Str)`, `(Str, U64)`, `{ s : Str }`, `List(U8)`, `List(Str)`, a nominal type that opts in (`over_nominal_field.roc`) | ok: missing method | ok: missing method |

So the bug is in the encoder only, for a nominal type over a primitive builtin (`Str` or a number type), below a record, tuple or tag. Over `Bool`, the same encode crashes the compiler. Open issue #12288 crashes in the same phase, but its trigger is a `parser_for` of a record type in a custom format, so it can be another bug. The workaround in the platform is a record backing (`Secret :: { text : Str }`, `Js.Ref :: { id : U32 }`), with a must-not-compile check (`api-probe/modules-check/secret_log.roc`, `secret_cbor.roc`, `ref_cbor.roc`).

## Bug 2: "type not determined" for a value that two formats parse (#12310)

A function with no annotation gives a value that `Json` parsed. A function with a `where` clause on a second format's `parser_for` takes it. The annotation of the result gives the type. The checker gives "type mismatch" with the same type on both sides, and "type not determined". With one format, or with an annotation on the first function, it compiles.

`type-not-determined/tiny.roc`, with `Tiny.roc`, a format of 13 lines that reads one `U64`:

```roc
import Tiny

wrap : ({} -> Try(a, e)) -> ({} -> Try(a, e)) where [a.Tiny.Parseable([Empty])]
wrap = |f| f

load = |{}| Json.parse("7")

number : {} -> Try(U64, _)
number = wrap(load)

main! = |_args| {
	echo!(Str.inspect(number({})))
	Ok({})
}
```

Expected: `Ok(7)`. Got:

```
── ✗ type mismatch ── tiny.roc:12:15
number = wrap(load)
              ^^^^
This argument has the type:
    {} -> Try(a, [InvalidJson(Str)])
      where [ a.parser_for : Tiny -> (List(U8) -> Try({ rest: List(U8), value: a }, [Empty])) ]
But wrap needs the first argument to be:
    {} -> Try(a, e)
      where [ a.parser_for : Tiny -> (List(U8) -> Try({ rest: List(U8), value: a }, [Empty])) ]

── ✗ type not determined ── tiny.roc:12:10
Nothing in this program determines the type this parser_for method is called on.
```

The `Json` constraint of `load` is not in the type that the message shows.

| Case (`type-not-determined/`) | Change | Result |
| --- | --- | --- |
| `tiny.roc` | none | BUG: type mismatch, type not determined |
| `tiny_annotated.roc` | `load : {} -> Try(U64, [InvalidJson(Str)])` | ok: `Ok(7)` |
| `tiny_one_format.roc` | `load` uses `Tiny`, not `Json` | ok: `Ok(7)` |

Other variants, checked on `nightly-2026-10-14-38a3029` while the repro was made smaller (not kept as files):

| Variant | Result |
| --- | --- |
| `Cbor` (`api-probe/cbor/Cbor.roc`) in place of `Tiny`, a record type in place of `U64` | BUG |
| A closed error row in the `where` clause, in place of `..errs` | BUG |
| Only an `encoder_for` constraint of the second format (no `parser_for`) | ok |
| `Json` for both, or `Cbor` for both | ok |
| The original shape: `Memo.new({ load!: load_jwks! })` with `jwks : Memo(Jwks, ...)` (`api-probe/modules-check/app.roc`) | BUG, fixed there with an annotation on `load_jwks!` |
