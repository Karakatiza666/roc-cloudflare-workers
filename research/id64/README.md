# Id64: a 64-bit id type for D1 (probe)

Question: can the platform give apps a type for 64-bit ids with no casts and no math? Answer: yes.

| File | Content |
| --- | --- |
| `Id64.roc` | The type. Opaque over `{ bits : I64 }`. CBOR and SQL form: I64 text. `Id64.Web`: U64 text in any format, for browsers. A bare `Id64` in JSON does not compile (marker `encode_bytes`). Derived `is_eq`, `to_hash`. No `is_lt`, no number methods. |
| `app.roc` | Tests: U64 and I64 range, bytes, text, `Dict` key, inspect, CBOR write and read (`int_from_text` on and off), tuple item, row, float above 2^53, JSON. |
| `must-not-compile.sh` | `id + 1`, `id < id`, `id.bits`, a literal as `Id64`, `u64 == id` fail `roc check`. A control compiles. |

Run, from the submodule root:

```sh
ROC=$(bench/get-roc.sh) ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache $ROC test research/id64/app.roc
research/id64/must-not-compile.sh
```

Method rules of the compiler that this probe found:

| Rule | Effect |
| --- | --- |
| A nominal type opts in to `is_eq`, `to_hash` with `name : _` | Equality and `Dict` keys work. |
| A hand-written `parser_for` and `encoder_for` need a `where` clause on the format (`encoding.parse_str`, `encoding.parse_i64`, `encoding.encode_str`) | The type needs no import of `Cbor`. The same code serves CBOR and JSON. |
| The parse state is a value | A parser can try `parse_str`, then `parse_i64` at the same item. |
| An opaque type has only the methods that it declares | `+`, `<` give "missing method". A bare `Id64 :: I64` is the same. |

Now in the platform: `platform/Id64.roc` (`pf.Id64`), with these tests as `expect`s and the must-not-compile cases in `conformance/must-not-compile.sh`. Two changes from this prototype: a bare `Id64` does not read JSON (the parser needs the marker `parse_bytes`), and `Id64.Web` reads text only (a JSON number is an error). This directory stays as the record of the prototype.
