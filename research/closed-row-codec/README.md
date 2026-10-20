# A row alias closed with `[]` has no derived codec in a function signature

Upstream issue: https://github.com/roc-lang/roc/issues/12489 (filed 2026-10-20).

Date: 2026-10-20. This is Q5 of `research/n5-rpc-errors/README.md` (`InfraOr([])` has no codec), with no platform and no package. It uses the builtin `Json`.

## Result

| Item | Finding |
| --- | --- |
| Trigger | A function parameter or return type `Ab([])`, where `Ab(r) : [A, B, ..r]`. `Json.to_str` gives `missing method encoder_for`, and `Json.parse` gives `missing method parser_for`. |
| Type in the message | `[A, B]`: the same type as `ok_written.roc`, which compiles. |
| By design? | No evidence. The tag_unions docs say only that `[A, ..[]]` written inline does not parse yet. The error prints the closed union `[A, B]`, and a value annotation `x : Ab([])` (`ok_value.roc`) has a codec. |
| Workaround | Write the union out (`[A, B]`), or close the row with a tag (`Ab([C])`). In the platform: a second list for "no domain error". |

## Smallest repro (`repro.roc`)

```roc
Ab(r) : [A, B, ..r]

enc : Ab([]) -> Str
enc = |x| Json.to_str(x)

main! = |_args| {
	echo!(enc(A))
	Ok({})
}
```

Expected: `"A"`. Got:

```
── ✗ missing method ───────────────────────────────────────────── repro.roc:4:11

A where clause requires the encoder_for method here, but the type being used
doesn't have that method.

enc = |x| Json.to_str(x)
          ^^^^^^^^^^^^^^

The value's type, which does not have a method named encoder_for, is:

    [A, B]
```

## Cases

| File | Type | Expected | 2026-10-12-2664a27 | 2026-10-18-1df370f | 2026-10-19-601b54c (latest) |
| --- | --- | --- | --- | --- | --- |
| `repro.roc` | `enc : Ab([]) -> Str` | `"A"` | missing `encoder_for` | same | same |
| `payload.roc` | `Ab(r) : [A(Str), B, ..r]`, `Ab([])` | `{"A":"a"}` or similar | missing `encoder_for` | same | same |
| `parse.roc` | `dec : Str -> Try(Ab([]), _)` | `Ok(A)` | missing `parser_for` | same | same |
| `ok_written.roc` | `enc : [A, B] -> Str` | `"A"` | `"A"` | same | same |
| `ok_plain_alias.roc` | `Ab : [A, B]` (no row) | `"A"` | `"A"` | same | same |
| `ok_tag.roc` | `enc : Ab([C]) -> Str` | `"A"` | `"A"` | same | same |
| `ok_value.roc` | `x : Ab([])`, `Json.to_str(x)` in `main!` | `"A"` | `"A"` | same | same |
| `ok_parse_written.roc` | `dec : Str -> Try([A, B], _)` | `Ok(A)` | `Ok(A)` | same | same |
| `open_row.roc` | `enc : Ab(r) -> Str` (rigid open row) | error | missing `encoder_for` | same | same |
| `open_union.roc` | `enc : [A, B, ..] -> Str` | error | missing `encoder_for` | same | same |

`open_row.roc` and `open_union.roc` are controls: an open row can have other tags, so the error is correct there.

## Run

```sh
ROC=$(bench/get-roc.sh nightly-2026-10-19-601b54c)
ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache research/closed-row-codec/run.sh "$ROC"
```
