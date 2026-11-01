<!-- Draft for roc-lang/roc. Not posted. Repro files next to this one:
     upstream_i128_narrow.roc (= test/wasm/i128_narrow.roc below), upstream_run.mjs (= run.mjs below).
     Searched issues and PRs (I128, to_u8_try, to_i8_try, OutOfRange, wasm dev backend, wasm32 dev) on 2026-11-02: no existing report.
     #12264 (closed) is a different bug: the wrong error tag when a builtin's Try error is widened. -->

# Title

`--target=wasm32 --opt=dev`: `I128`/`U128` `.to_u8_try()`, `.to_u16_try()`, `.to_i8_try()`, `.to_i16_try()` return `Err(OutOfRange)` for in-range values

# Body

With the wasm dev backend, a narrowing `_try` conversion from `I128` or `U128` to an 8-bit or 16-bit integer returns `Err(OutOfRange)` for an in-range value such as `3`. Conversions to 32-bit and 64-bit types are correct, and `I64.to_u8_try` is correct. `--opt=speed` is correct, and native x64 is correct with `dev`, `speed` and `interpreter`.

I found this through a real program: a CBOR decoder that reads each integer as an `I128` and then calls `to_u8_try` could not decode any `List(U8)` in a `--opt=dev` wasm build.

## Reproduction

Put this file in `test/wasm/` (it uses the test platform there; `json_input!` only makes `n` a run-time value, because a literal `3.I128` is constant-folded and does not show the bug):

`test/wasm/i128_narrow.roc`

```roc
app [main!] { pf: platform "./platform/main.roc" }

import pf.FallibleHost

main! = || {
	n : I128
	n = FallibleHost.json_input!({}).count_utf8_bytes().to_i128() - 18 # 3, not a constant
	"u8=${Str.inspect(n.to_u8_try())} u16=${Str.inspect(n.to_u16_try())} i8=${Str.inspect(n.to_i8_try())} i16=${Str.inspect(n.to_i16_try())} u32=${Str.inspect(n.to_u32_try())} i64=${Str.inspect(n.to_i64_try())}"
}
```

`run.mjs` (Node; calls `wasm_main` and prints the returned `Str`):

```js
import { readFileSync } from "node:fs";
let mem;
const text = (p, n) => new TextDecoder().decode(new Uint8Array(mem.buffer, p, n));
const env = new Proxy({}, { get: (_, name) => (p, n) => {
	if (name === "echo") return;
	console.log(`${String(name)}(${typeof p === "number" && typeof n === "number" ? text(p, n) : ""})`);
} });
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
mem = instance.exports.memory;
const p = instance.exports.wasm_main();
console.log(text(p, instance.exports.wasm_result_len()));
```

```
$ cd test/wasm
$ roc build --target=wasm32 --opt=dev --no-cache --output=dev.wasm i128_narrow.roc && node run.mjs dev.wasm
u8=Err(OutOfRange) u16=Err(OutOfRange) i8=Err(OutOfRange) i16=Err(OutOfRange) u32=Ok(3) i64=Ok(3)

$ roc build --target=wasm32 --opt=speed --no-cache --output=speed.wasm i128_narrow.roc && node run.mjs speed.wasm
u8=Ok(3) u16=Ok(3) i8=Ok(3) i16=Ok(3) u32=Ok(3) i64=Ok(3)
```

**Expected:** `--opt=dev` gives the same output as `--opt=speed`.

## What is affected

| Source | Target | wasm32 `--opt=dev` |
| --- | --- | --- |
| `I128`, `U128` | `U8`, `U16`, `I8`, `I16` | wrong: `Err(OutOfRange)` for in-range values (seen: `3`, `-3`, `21000.to_u16_try()`) |
| `I128`, `U128` | `U32`, `U64`, `I32`, `I64` | correct |
| `I64` | `U8` | correct |

Out-of-range values give `Err(OutOfRange)`, as expected (but see the cause: the discriminant is read from a byte that the code does not write, so this is by chance).

## Versions

- `nightly-2026-10-31-f7bef6b`: fails
- `nightly-2026-11-01-48d3369` (the newest nightly): fails
- The code below is the same on `main` at 4ffc27abf1 (2026-11-01).
- Linux x86_64, Node 26.

## Probable cause

`src/backend/wasm/WasmCodeGen.zig`, `emitI128TryNarrow` (used by all `i128_to_*_try` and `u128_to_*_try` ops with a target narrower than 128 bits):

```zig
const payload_wasm_size: u32 = if (target_bytes <= 4) 4 else 8;
const disc_offset: u32 = payload_wasm_size;
```

For a 1-byte or 2-byte target this writes the `Ok` discriminant at offset 4. The layout of `Try(U8, [OutOfRange])` has the discriminant at offset 1 (offset 2 for `U16`/`I16`). That is what `emitIntTryBound` uses for the 64-bit sources (`emitIntTryResult(vt, size, size)`, discriminant at offset `size`), and that is why `I64.to_u8_try` is correct. The caller reads the discriminant from byte 1 (or 2). The `store8`/`store16` of the payload does not write that byte, and the stack slot is not zeroed there, so the caller sees a stale byte (`0` in my runs, so `Err`). For 4-byte and 8-byte targets, `payload_wasm_size` equals the real payload size, so those are correct.
