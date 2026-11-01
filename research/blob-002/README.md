# A BLOB does not read into `List(U8)` (report of 2026-11-01)

Report: release 0.0.2, `db.all!("SELECT x'0102ff' AS bl", Sql.none)` into `List({ bl : List(U8) })` or `List({ bl : Cbor.Bytes })` gives `Err(Infra(BadData("column bl: the value does not fit the type")))`. The conformance check `dec D1 BLOB` passes.

Result: not a platform bug. The app was built with `--opt=dev`. On nightly 2026-10-31 (f7bef6b), the dev backend for wasm32 gives a wrong `to_u8_try`, `to_u16_try`, `to_i8_try` and `to_i16_try` of an `I128`. roc-cbor 0.2.2 reads each integer as an `I128` (`int`) and then calls `to_<T>_try`. D1 gives a BLOB as an array of numbers, so each byte goes through `parse_u8`.

| Build | Output of `narrow2.roc` (`n : I128 = 3`) |
| --- | --- |
| wasm32 `--opt=dev` | `u8=Err(OutOfRange) u16=Err(OutOfRange) u32=Ok(3) u64=Ok(3) i8=Err(OutOfRange) i16=Err(OutOfRange) i32=Ok(3) i64=Ok(3)`. `I64.to_u8_try` is good. |
| wasm32 `--opt=speed` (the default) | all `Ok(3)` |
| native x64 `dev`, `speed`, `interpreter` (`i128_try.roc`) | all good |

| File | What it shows (dev / speed) |
| --- | --- |
| `app_bundle.roc`, `app_local.roc` | The report, with the 0.0.2 bundle and with the source tree: `all!`, `first!`, `batch!`, `with_session!` with `List(U8)` and `Cbor.Bytes`. All `BadData` with dev, all good with speed. `{ x : Bool, y : U64 }` is good with both. |
| `narrow.roc` | `Cbor.parse` with no D1: `U8` from `[0x03]` and `List(U8)` from an array fail with dev. `List(U8)` from a byte string (`0x43 ...`) and `List(U64)` are good. |
| `narrow2.roc` | The `I128` conversions above, with no CBOR. |
| `i128_try.roc` | The same on the native targets (no platform). |
| `run.mjs` | `node run.mjs <app.wasm> [miniflare dir]`: `GET /` (or `PROBE_PATH`) in Miniflare with a local D1. `REG=1` uses the entry and options of the Talon registry harness (`../worker/tests/` of the Talon checkout: a Proxy of `env.DB`, `d1Persist`): no change. |

Build: `roc build --target=wasm32 --no-cache --opt=<dev|speed> --output=<out>.wasm <file>.roc`, from this directory, with the roc of `compat/last-stack-first-nightly`.

The conformance app built with `--opt=dev` fails its own check: `node conformance/run.mjs <dev.wasm> "dec D1 BLOB"` gives `bytes=Err(Infra(BadData("column b: the value does not fit the type")))`, the same for `list`. With `speed` it passes.

The Miniflare version (wrangler 4.151.0 and 4.156.0), the D1 method and the harness have no effect. Only the build mode has.
