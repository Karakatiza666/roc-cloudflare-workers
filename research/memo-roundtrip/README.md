# A `Memo` value that does not come back from its CBOR form (Talon slice 108b, P1)

Report: a `Memo(List(Jwk.Key))` (roc-jwt 0.0.1) read the JWKS again at each `get!`, with no error and no log line. W2 cases of the Talon registry had 3 and 12 JWKS loads where 1 was expected.

Result: the cause is not the codec rules and not the platform. It is the compiler bug of `research/blob-002/` (draft upstream issue there): the wasm32 dev backend (`--opt=dev`) gives `Err(OutOfRange)` for `I128.to_u8_try`, `to_u16_try`, `to_i8_try` and `to_i16_try` of a value in range. roc-cbor 0.2.2 reads each integer as an `I128`, so a `List(U8)` (written as an array) does not read back. The Talon W2 harness builds the Worker with `--opt=dev`.

## Minimal failing type

| Type (value from the request, not a constant) | wasm32 `--opt=dev`, roc-cbor 0.2.2 | `--opt=speed` | `--opt=dev`, roc-cbor 0.2.3 |
| --- | --- | --- | --- |
| `List(U8)`: `[n, 2]` | `Err InvalidCbor(1)` | `same=True` | `same=True` |
| `[Rsa({ n : List(U8), e : List(U8) })]` | `Err InvalidCbor(13)` | `same=True` | `same=True` |
| `{ kid : Try(Str, [Missing]), alg : Try(Str, [Missing]) }` | `same=True` | `same=True` | `same=True` |
| Tag unions with `Str`, `U64`, a nested tag; a record with a tag | `same=True` | `same=True` | `same=True` |
| `Cbor.Bytes` (a byte string) | `same=True` | `same=True` | `same=True` |
| `I128` to `U8`, `U16`, `I8`, `I16` with `_try` | `Err(OutOfRange)` | `Ok` | (no change: compiler) |
| `I128` to `U32`, `I32`, `U64`, `I64`, and `I64` or `U64` to `U8` | `Ok` | `Ok` | `Ok` |

So the `Try` fields and the tag union are not the cause. A constant value can hide the bug: the compiler folds it (a warning "known at compile time"), so the probes take `n` from the request. Native x64 (`dev`, `speed`) and the interpreter (`roc test`) are correct.

Seen on nightly 2026-10-31 (f7bef6b) and 2026-11-01 (48d3369).

## Files

| File | What |
| --- | --- |
| `probe.roc` | `roc test`: the roc-jwt shape round-trips in the interpreter (6 expects pass) |
| `native.roc`, `jwt-probe.roc`, `jwks.json` | Native builds (`dev`, `speed`): the shape and a real `Jwk.parse_set` result round-trip. `jwt-probe.roc` reads roc-jwt by a local path (research only). |
| `ProbeRoutes.roc.txt` | The probe routes that were in `conformance/MemoRoutes.roc` (the integer conversion table above) |
| `build-conf.sh` | Builds only the bench host and `conformance.wasm` (env `OPT`, `OUT_WASM`, `SKIP_HOST=1`) |
| `dev-check.sh` | The memo checks with a `--opt=dev` build; `ROC_CBOR=<roc-cbor>/src/main.roc` replaces the 0.2.2 URL |
| `talon/repro.sh`, `talon/keys-variant.py` | A copy of the Talon registry Worker with `KeySet = { fetched_ms, keys : List(Jwk.Key) }`, built and run with the `oidc` W2 cases. `OPT=dev` (default, as Talon): 7 of 8 fail (3 to 12 JWKS reads where 1 or 2 are expected). `OPT=speed`: 8 of 8 pass. |

## Fixes

| Part | Change |
| --- | --- |
| roc-cbor | `narrow`: the reader converts the `I128` to an `I64` first, then to `U8` to `I32`. Commits: 0.4.1 on `main` (`9489d62`), 0.2.3 on the branch `release-0.2.x` from the tag 0.2.2 (`2b9437f`). `tests/ints.roc` (12 expects). Not released. |
| Platform, `Memo.get!` | The write check: at a miss, parse the bytes before the pin. A value that does not parse back is not pinned, and `pf.memoUnreadable(name, error)` logs one line for each name in the isolate (`MODULES.md` 9). A pin of an older type still loads again with no log line. |

With `--opt=dev` and roc-cbor 0.2.2 the line is: `Memo "conformance-jwks": the value of load! does not parse back from its CBOR form (InvalidCbor(42) at keys[0].material.Rsa.e[0]). It is not pinned, so each get! runs load! again. Use a type that round-trips (MODULES.md 9).`

`dev-check.sh` results:

| Build | Memo checks |
| --- | --- |
| `--opt=dev`, roc-cbor 0.2.2 | 3 fail: the roc-jwt round trip, the small integers, the jwks loads once (with the log line above) |
| `--opt=dev`, `ROC_CBOR=../roc-cbor-0.2.x/src/main.roc` (0.2.3) | all pass |
| `--opt=dev`, roc-cbor 0.4.1 (`main`) | all pass: the platform compiles with 0.4.x too |
