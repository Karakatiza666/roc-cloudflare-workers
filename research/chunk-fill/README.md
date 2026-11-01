# Body.chunk! fill (Talon slice 111, section 8, P1 and P4)

Input: `Body.chunk!` of an outbound `fetch` body gave chunks of about 4 KiB in Miniflare: 28,766 chunks (crossings) for 110 MB. P4: `Worker.new({ fetch! })` gives a confusing type error.

## Files

| File | What |
| --- | --- |
| `probe-worker.js`, `probe.capnp`, `probe.mjs` | JS only, no platform. The parts of a workerd body stream (a request body, a `fetch` body), and three ways to see that the next part is not ready: none (always wait), microtasks, a timer of 0 ms. `WORKERD=<path> node research/chunk-fill/probe.mjs` |
| `measure.mjs` | `bench/out/app_stream.wasm`, `POST /chunk?fill=`: 110 MB through `chunk_with!` with fill 1, 16 KiB, 64 KiB, 256 KiB. Node (`cf-node.mjs`) and workerd (`bench/config-stream.capnp`). `WORKERD=<path> node research/chunk-fill/measure.mjs bench/out/app_stream.wasm` |
| `measure-check.mjs` | The Miniflare measure: 110 MB of an `Http.open!` body (`conformance/BodyRoutes.roc`). Copy it to `conformance/checks/zz-measure.mjs`, run `node conformance/run.mjs bench/out/conformance.wasm measure`, remove the copy. |
| `shorthand.roc`, `shorthand_comma.roc` | P4: `Worker.new({ fetch! })` (type mismatch) and `Worker.new({ fetch!, })` (no errors) |

## Probe: how to see that a part is not ready (workerd 2026-10-12, 110 MB)

| Source | Way | Calls | Parts | Mean chunk | Note |
| --- | --- | --- | --- | --- | --- |
| `fetch` body | one part for each call | 29,068 | 29,069 | 3,968 B | parts of 1 KiB to 4 KiB |
| `fetch` body | always wait to 64 KiB | 1,744 | 28,461 | 66,137 B | a slow stream would wait for 64 KiB |
| `fetch` body | race with 4 microtasks | 28,183 | 28,184 | 4,093 B | a workerd read needs a turn of the event loop: microtasks never see it ready |
| `fetch` body | race with `setTimeout(0)` | 1,760 | 28,162 | 65,536 B | chosen |
| request body | race with `setTimeout(0)` | 1,760 | 29,921 | 65,536 B | |

Decision: a part is ready when its read completes before a timer of 0 ms. When it is not, the call gives what it has, and the read stays in the read state of the stream (`pending` in `js/helpers.js`) for the next call. A slow stream (`/drip` of `conformance/run.mjs`: 5 parts of 100 B, 400 ms apart) gives 5 chunks at 1, 402, 802, 1202, 1602 ms.

## Measure: 110 MB, before (fill 1, the behavior of `chunk!` in 0.0.2) and after (fill 64 KiB)

| Where | fill_bytes | Crossings (chunks) | ms (best of 3) |
| --- | --- | --- | --- |
| Miniflare, `Http.open!` body | 1 | 28,161 | 1,472 |
| Miniflare, `Http.open!` body | 65,536 | 1,760 | 392 |
| Miniflare, `Http.open!` body | 262,144 | 440 | 356 |
| workerd, request body | 1 | 29,068 | 569 |
| workerd, request body | 16,384 | 6,967 | 340 |
| workerd, request body | 65,536 | 1,743 | 318 |
| workerd, request body | 262,144 | 438 | 324 |
| Node, parts of 4 KiB | 1 | 28,160 | 232 |
| Node, parts of 4 KiB | 65,536 | 1,760 | 74 |
| Node, parts of 4 KiB | 262,144 | 440 | 62 |
| Node, parts of 64 KiB | 1 | 1,760 | 28 |
| Node, parts of 64 KiB | 65,536 | 1,760 | 31 |

The workerd request body is limited by the socket of the client (about 300 ms for 110 MB). 64 KiB is the knee: 256 KiB gives 9 % more in Miniflare and nothing for the workerd request body. Default: 64 KiB (`Body.default_fill`).

## P4: `Worker.new({ fetch! })`

A language rule: `{ name }` with one name and no comma is a block that gives the value of `name`. No platform change. `MODULES.md` 2 has the error text and the fix (`{ fetch!: fetch! }`).
