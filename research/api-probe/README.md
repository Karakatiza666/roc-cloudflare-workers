# api-probe: facts for the app and platform API (`../../API.md`)

| File | Content |
| --- | --- |
| `worker.js`, `config.capnp` | workerd probe: compression formats, WebCrypto algorithms, `crypto.DigestStream`, the clock |
| `Js.roc` | The bridge value type and its byte format (API.md 5), with 4 `expect`s |
| `codec.mjs` | The JS side of the same byte format |
| `codec-test.mjs` | Same bytes as `Js.roc`, round trip with a handle, encode cost of D1 results |
| `Program.roc` | The ops of a program (API.md 6.2), all 10, and their encoder, as a `Js` array. A D1 query as 4 ops, two queries in one `Par`, `Array` and `Record` of slots. 3 `expect`s. |
| `program.mjs`, `program-test.mjs` | The JS interpreter of programs: roots, slots, all 10 ops, the J1 to J7 conversion with the i64 and depth limits, the ref table, status 0 to 3. Tested in Node against a fake D1 binding, a class with getters and timers. |
| `bench/main.roc` | Decode cost in Roc of 200 D1 rows, best of 7 rounds: to a `Js` tree, to typed rows, with direct integer reads (`Js2.roc`), and `Json.parse` (basic-cli 0.29.0, native). `bench/Js.roc` is a copy of `Js.roc`, because an app imports from its own directory. |
| `bench/rows.mjs`, `bench/decode.zig` | The same 200 rows from JS (`rows.bin`, same 51,385 bytes as Roc makes), decoded in Zig into a tree with the memory shape of Roc values: a lower bound for a decoder in the host |
| `glue-check/` | A platform with a hosted function that returns `Js`. `roc glue` shows the layout that a Zig decoder must write. |
| `handlers-check/` | A handler record with optional effectful fields that builds the one entry `event!` (API.md 10.1, AQ6). Run: `roc test Handlers.roc && roc run.roc`. Result on 10-12: passes, and prints `fetched /v1/pkg \| unhandled`. |
| `http-check/` | `roc-lang/http` 2.0.0 on the pinned nightlies (API.md AQ2) |
| `wrappers-check/` | `Io` (API.md 6.5) and `Memo` (7.1) as nominal types with function fields: `Io.both!` joins the error unions of two operations, and `jwks.get!()` runs an effectful `load!` from a record field. The crossing and the pin table are fakes. Run: `roc run.roc`. Result on 10-09 and 10-12: passes, and prints `Ok((16, "fetch+/jwks")) \| Err(HttpErr("TypeError")) \| Ok(8) \| Ok("key-1")` (API.md AQ7). |

Run:

```sh
WORKERD=<path to workerd>; $WORKERD serve config.capnp & curl -s localhost:8241; kill %1
roc test Js.roc && roc test Program.roc
node codec-test.mjs && node program-test.mjs
cd bench && roc build main.roc --opt=speed && ./main
node rows.mjs && zig build-exe decode.zig -O ReleaseFast -lc -femit-bin=decode && ./decode    # Zig 0.17
cd ../glue-check && roc glue <cloudflare-workers>/host/ZigGlue.roc out platform/main.roc
cd ../http-check && roc build main.roc && ./main
```

## Result (2026-10-15)

workerd `2026-10-12`, compatibility date `2026-10-01`:

| Feature | Result | Effect on the API |
| --- | --- | --- |
| `DecompressionStream('zstd')` | No: "must be either 'deflate', 'deflate-raw' or 'gzip'" | zstd decode must be wasm code (API.md 8) |
| `crypto.subtle.digest('BLAKE3')` | No: NotSupportedError | BLAKE3 must be wasm code (Roc builtin or host) |
| `crypto.DigestStream('SHA-256')` | Yes | SHA-256 of a stream with no copy into wasm |
| Ed25519 sign | Yes, 64 B | Checkpoint signatures through `Crypto` |
| RSASSA-PKCS1-v1_5 verify (JWT RS256) | Yes | OIDC tokens through `Crypto` |
| ECDSA P-256 verify | Yes | Sigstore bundles (P3) through `Crypto` |
| `crypto.subtle.timingSafeEqual` | Yes | Webhook HMAC compare |
| `Date.now()` in a busy loop | Moves 40 ms locally. On the edge the clock moves only at I/O (Cloudflare docs). | `Time.now!` is coarse on the edge |

Codec (24-core x86-64, Node 26; Roc nightly `2026-10-12`, native build):

| Case | 200 rows | 2,000 rows |
| --- | --- | --- |
| JS encode, rows as objects (D1 `.all()`) | 89 µs | 840 µs |
| JS encode, rows as arrays (D1 `.raw()`) | 45 µs | 498 µs |
| JS `JSON.stringify` + `TextEncoder`, rows as arrays | 20 µs | 234 µs |
| Roc: decode the byte format, then match into typed rows (first run, noisy) | 113 to 138 µs | not run |
| Roc: `Json.parse` of the same rows into typed rows (first run, noisy) | 234 to 244 µs | not run |

Decode of 200 rows, best of 7 rounds of 300, 2 runs (the row count comes from the clock, so the compiler cannot fold the decode):

| Decoder | µs |
| --- | --- |
| Roc: bytes to a `Js` tree only | 85 |
| Roc: bytes to a `Js` tree, then a match into typed rows | 99 |
| Roc: same, with direct integer reads (`Js2.roc`) | 121 to 125 (slower: the helper closure) |
| Roc: `Json.parse` into typed rows | 229 to 238 |
| Zig: bytes to a tree with the shape of Roc values (24 B headers, refcount word, strings of 23 B or less inline, UTF-8 check), then free | 24 to 26 (6 of 8 runs; 2 runs on a busy machine gave 35 and 53) |

So 85 % of the Roc decode is the tree, and Zig builds the same tree 3.4 times faster. With a Zig decoder, 200 rows cost about 45 (JS encode) + 25 (Zig) + 14 (Roc match) = 84 µs, against 160 µs now. These are native numbers. wasm32 numbers come in `PLAN.md` step 8g.

`roc glue` (nightly 10-12) on `glue-check/`: `Js` is not boxed. The recursion goes through `List`. On wasm32 a `Js` is 32 B: 24 B of payload, then a 1-byte tag at offset 24, align 8. The tags are numbered in alphabetical order (`Arr` 0 ... `Undefined` 10), not in the order of the source. The glue has `RocStr.fromSlice`, `RocList.allocate`, `incref` and `decref` for `Js`, and `comptime` checks of size, align and tag offset for 32-bit and 64-bit.

`roc-lang/http` 2.0.0 (the same hash as 1.0.0): `http-check/` builds and runs on nightlies 10-09 and 10-12 with no warning. `Request` is opaque, for a client (`uri`, `timeout_ms`, body `List(U8)`). `Response` is opaque (status, headers, body `List(U8)`). `Method` and `Header` are nominal.

Programs: `program-test.mjs` passes. `prepare`, `bind` and `raw` run in one crossing. A class instance comes back as a ref, `Fields` reads its getters, and a `Date` becomes milliseconds. A promise in `call!` gives status 2, a throw status 1, an unknown root status 3. After `clear`, the ref of the task is gone. A D1 batch of 2 statements is one crossing (`Array`). Two branches of `Par` that each wait 100 ms take about 100 ms. A throw in a branch is status 1 for that branch only. Two `Start` calls go to `Promise.all`. A BigInt of 2^64, a cycle and an array 100 deep are status 1. `Program.roc`: 7 of 7 `expect`s pass with `Js.roc` on 10-09 and 10-12.

Revert checks (each test fails):

| Revert | Test |
| --- | --- |
| `Js.roc`: a `Ref` that reads 3 bytes in place of 4 | The round-trip `expect` |
| `Program.roc`: the `expect` asks for 3 ops | The program `expect` |
| `program.mjs`: `call!` awaits a promise and does not give status 2 | `program-test.mjs` |
| `program.mjs`: `Fields` copies own properties, not getters | `program-test.mjs` |
| `program.mjs`: `Par` runs its branches one after the other | `program-test.mjs` ("par took 201 ms") |
| `program.mjs`: `Start` is awaited like `Call` | `program-test.mjs` (status 2 in `call!`) |
| `program.mjs`: no depth limit, or no i64 range check | `program-test.mjs` |
| `program.mjs`: `Array` keeps the arg form | `program-test.mjs` |
| `program.mjs`: a bad root in a branch is status 1 | `program-test.mjs` |
| `Program.roc`: `Par` or `Record` encodes no content | The `Par` or the `Array` and `Record` `expect` |

## Conclusion

- The byte format costs less than JSON in total (200 rows: about 145 µs with the Roc decoder, 84 µs with a Zig decoder, against about 250 µs for JSON), but all are large next to a whole request of the bench app (200 to 280 µs). A module must not send many rows through Roc when it does not need them.
- For a large read that goes to the client unchanged, the cheapest path is JSON that SQLite builds (`json_group_array`), passed through as a body handle with no decode in Roc (API.md 9, RF7 of the audit).
- 85 % of the Roc decode time is the `Js` tree. A decoder in the Zig host, with the glue types, makes it 3.4 times faster (API.md 5.1).
- The Roc decoder is a first version (byte-by-byte integer reads, a `Js` tree, then a match). A decoder that goes straight to typed records through the codec protocol (`parser_for`) could remove the tree. AQ5 in API.md.
