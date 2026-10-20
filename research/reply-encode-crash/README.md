# The derived encoder of a generic nominal type in a returned lambda crashes the compiler

Date: 2026-10-20. This is the crash that makes `Rpc.on` (`platform/Rpc.roc`) write the reply head by hand (`ok_head`, `err_head`). Before, the repro was `research/e1-errors/mod/app.roc` with `Cbor.encode(Reply.Ok(r))` in `on`.

Upstream issue: https://github.com/roc-lang/roc/issues/12482 (filed 2026-10-20).

## Result

| Item | Finding |
| --- | --- |
| Trigger | A function that returns a lambda. The lambda encodes a value of a generic nominal type with a derived `encoder_for : _` (`W(a)`), and the payload is a captured value of the type variable `a`. |
| Format | Any. The builtin `Json` crashes (`repro.roc`), and a format of 25 lines does too (`Fmt.roc`, `custom_format.roc`). No package and no platform. |
| Commands | `roc check`, `roc build`, `roc <file>`: all give SIGSEGV in "post-check monotype", fault address 0x330. |
| Specific to the encoder | `is_eq : _` in the same shape is OK (`ok_is_eq.roc`). |
| Workaround in the platform | Encode the type variable alone (`Cbor.encode(r)`, as `ok_plain.roc`) and write the bytes of the wrapper by hand. |
| Workaround when the value is known before the lambda | Encode before the lambda and capture the result (`ok_outside.roc`). |

## Smallest repro (`repro.roc`)

```roc
W(a) := a.{
	encoder_for : _
}

f = |r| |{}| Json.to_str(W.(r))

main! = |_args| {
	echo!(f(7.U64)({}))
	Ok({})
}
```

Expected: `7`. Got:

```
Segmentation fault (SIGSEGV) in the Roc compiler.
Fault address: 0x330

Work in progress on thread 861816 (compile worker 12), outermost first:
  post-check    monotype
```

## Cases

| File | Change from `repro.roc` | 2026-10-12-2664a27 | 2026-10-18-1df370f | 2026-10-19-601b54c (latest) |
| --- | --- | --- | --- | --- |
| `repro.roc` | none | crash | crash | crash |
| `tag.roc` | `W(a) := [W(a)]`, the form of `Rpc.Reply` | crash | crash | crash |
| `custom_format.roc` | own format `Fmt.roc`, annotation with `where [r.Fmt.Writable]` | crash | crash | crash |
| `helper.roc` | the lambda calls a top-level `enc = \|r\| Json.to_str(W.(r))` | crash | crash | crash |
| `custom_format_ok.roc` | `Fmt.encode(Reply.Ok(7.U64))` with no lambda | `[79, 107, 7]` | same | same |
| `ok_no_lambda.roc` | `f = \|r\| Json.to_str(W.W(r))` | `{"W":7}` | same | same |
| `ok_mono.roc` | `W := [W(U64)]`, not generic | `{"W":7}` | same | same |
| `ok_local.roc` | the lambda is in `main!`, not returned by a function | `{"W":7}` | same | same |
| `ok_outside.roc` | encode before the lambda, capture the text | `7` | same | same |
| `ok_plain.roc` | `Json.to_str(r)`, no `W` | `7` | same | same |
| `ok_is_eq.roc` | `is_eq : _` and `==` in place of the encoder | `True` | same | same |

## Run

From the submodule root:

```sh
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
research/reply-encode-crash/run.sh $(bench/get-roc.sh nightly-2026-10-19-601b54c)
```

`run.sh` uses `--no-cache` for each case.

## Issue

Filed as roc-lang/roc#12482. No open issue matched before (searches: monotype, SIGSEGV, post-check, encoder_for, closure, lambda). The closed #12288 crashes in the same phase, but its trigger is `parser_for` of a record, and it is fixed.
