# zstd speed of the Native ops (2026-11-02)

The problem: `Native.ZstdStream` (on `std.compress.zstd`) decoded about 40 MB of output per second. basic-cli 0.26.0 (22.3 MB packed, 82.8 MB out) took 1.4 s of CPU in Node and 4.6 s in workerd (roc-tar bench). The registry Worker streams archives up to 256 MiB unpacked inside a 30 s CPU limit, and Workers bills CPU time.

The result: the host now uses a pure Zig port of the libzstd 1.5.7 decoder (`hostlib/zstd/`, module `zstd_dec`, ReleaseSafe). The stream is 13 to 23 times faster, the stack of a zstd op is 6 KB (was 274 KB), and the size of an app does not change.

| Size (production and bench builds, before: a6230bb) | Before B | After B |
| --- | --- | --- |
| `platform/targets/wasm32/host.wasm` (an object, not linked) | 1,015,734 | 1,023,584 (+7.9 KB, with `feed`) |
| `bench/out/app_deep.wasm` (an app that calls `zstd_decode!`: all Native ops are linked) | 400,656 | 400,617 (-39) |
| `bench/out/app_prod.wasm` (no Native) | 428,222 | 428,127 |

## 1. Files

| File | Use |
| --- | --- |
| `fetch.sh` | Gets the third-party decoders into `.cache/src` (pinned commits, not committed) |
| `build.sh` | Builds a probe wasm for each variant: the harness of `research/native/harness/harness.zig` (real `hostlib/alloc.zig`, the Native ops of `native.zig`) with the `zstd.zig` of the variant. `MODES` (Small, Fast) is the mode of the harness, `MODO` the mode of the decoder module. |
| `variants/<name>/zstd.zig` | One decoder behind the API of `hostlib/native/zstd.zig`. `std` is the old file (a6230bb). `new` is the file of hostlib now (copied at build). |
| `core.mjs`, `run.mjs` | Node: open a stream, push the file in `CHUNK` byte pieces through `native.call`, close. CPU ms (median), MB/s of output, peak live bytes. `VERIFY=1`: SHA-256 of the output. |
| `worker.mjs`, `run-workerd.mjs` | The same loop in workerd (the input is a data module). Wall time of the client (workerd stops its clocks while a Worker runs). |
| `stack.mjs` | Stack use of `zstd_decode` and of a stream (paint and scan) |
| `sections.mjs`, `sizes.mjs` | Section sizes, largest functions of a wasm |
| `difffuzz/` | Native, ReleaseSafe: damaged frames through the zaxified decoder and libzstd (C). Same bytes or both an error. |
| `tagfuzz/` | Native, ReleaseSafe, leak check: damaged frames through the old and the new `hostlib/native/zstd.zig` (`decode` and a stream in random chunks). Counts how the answers compare. |

Run: `./fetch.sh; ./build.sh; node run.mjs out/<v>.wasm 5 <file.tar.zst>`.

## 2. Measurements

Input: basic-cli 0.26.0 (`GddgvsGjiNXr...tar.zst`, 22.3 MB packed, 82.8 MB out, window 2 MiB, one frame, no checksum). Pushes of 64 KB. Node 26.7, workerd of wrangler. The machine had other load: runs move by about 15 percent (two numbers: two runs). Size: the probe wasm (harness, allocator, all Native ops). The std row is the size before.

| Variant | Language | Node MB/s (CPU ms) | workerd MB/s | Probe wasm B | Size vs std |
| --- | --- | --- | --- | --- | --- |
| `std` (the old decoder), ReleaseSmall | Zig | 44 (1883) | 35, 38 | 101,165 | 0 |
| `std`, all ReleaseFast | Zig | 32 (2588) | | 665,252 | +564 KB |
| `std`, 4 windows of slack (fewer window moves) | Zig | 47 | | 101,165 | 0 |
| muhammad-fiaz/zstd.zig 0.0.5, Small | Zig | 90 (925) | 78 | 97,715 | -3 KB |
| muhammad-fiaz/zstd.zig 0.0.5, Fast | Zig | 114 (724) | | 697,834 | +597 KB |
| zaxified `DecompressStream`, Small | Zig | 489 | 575 | 264,260 | +163 KB |
| zaxified `DecompressStream`, decoder module Fast | Zig | 728 to 942 | 624 to 787 | 259,559 | +158 KB |
| zaxified `DecompressStream`, decoder module Safe | Zig | 687 to 905 | 574 | 281,703 | +180 KB |
| libzstd 1.5.7 (C, decompress only, `-O3`) | C | 842 to 928 | 731 | 133,001 | +32 KB |
| libzstd 1.5.7 (C, decompress only, `-Os`) | C | 833 to 980 | 688 to 827 | 113,297 | +12 KB |
| new: zaxified piece API, own ring buffer, decoder module Small | Zig | 606 | | 102,964 | +2 KB |
| new, decoder module Safe (chosen) | Zig | 801 to 1008 | 465 to 521 | 119,780 | +19 KB |
| new, decoder module Fast | Zig | 1129 | 698 | 98,524 | -3 KB |

Native `zstd -d` (1.5.7) of the same file: 50 ms (1.6 GB/s).

Other files, new (Safe) against std, Node, 64 KB pushes:

| File | Out | new MB/s | std MB/s | Peak live new / std |
| --- | --- | --- | --- | --- |
| basic-cli `4KBAoiBazDfi` (28.1 MB packed, window 2 MiB) | 99.6 MB | 767 | 36 | 3.97 / 4.01 MB |
| `big-10m.tar.zst` (zstd -19 of a binary, window 8 MiB) | 33.5 MB | 329 | 32 | 9.57 / 12.82 MB |
| basic-cli, pushes of 4 KB | 82.8 MB | 341 (Node) / 521 (workerd) | | 3.30 MB |

| Stack | new | std |
| --- | --- | --- |
| `zstd_decode`, a stream push | 6 KB | 274 KB |

### What the numbers say

| Finding | Effect |
| --- | --- |
| The std decoder is slow in itself: it reads bits one byte at a time and walks a Huffman tree per bit. ReleaseFast does not help (it was slower), more slack does not help. | Candidates 1 and 4 (build mode, buffer sizes, copies in `native.zig`) give nothing on the std decoder. |
| A Zig option comes close to libzstd: the zaxified port is equal to libzstd in workerd with ReleaseFast, and at 60 to 100 percent of it with ReleaseSafe. | The user prefers Zig: it is the choice. |
| `Decompressor.init` of zaxified copies a default state (with a 128 KB literal buffer) from a constant: 170 KB of zero bytes in the data section. | `newDec` in `hostlib/native/zstd.zig` sets the fields one by one. The size cost goes from +163 KB to +19 KB. |
| A window that moves down in its buffer (`copyForwards`, a byte loop in ReleaseSmall) cost 2 times the decode. | The stream buffer is a ring (window + 2 blocks), as in `ZSTD_decompressStream`: no copy of the window. 324 to 1008 MB/s. |
| ReleaseSafe costs about 10 to 35 percent against ReleaseFast. | Kept: bounds checks on a decoder of input from the network. A one-line change in `build.zig` gives Fast. |

## 3. The candidates

| Candidate | Licence | Maintenance | Zig 0.17 | Stream | Bad input | Result |
| --- | --- | --- | --- | --- | --- | --- |
| `std.compress.zstd` | MIT | Zig | yes | yes (hostlib stream) | ok | slow |
| muhammad-fiaz/zstd.zig 0.0.5 (`aeec26c`) | MIT | 1 author, 17 stars, active | yes | `StreamingDecompressor`. It copies its whole window after each block and keeps all input in a list. | not checked (slow) | 2 to 3 times std |
| zaxified/zig-libs `modules/zstd` (`ccde063`) | MIT, and BSD of libzstd (port) | 1 author, 9 stars, made 2026-07, active, many tests and fuzz targets | yes | `DecompressStream` and the piece by piece `Decompressor.decompressContinue` | 500,000 damaged frames against libzstd: 0 differences, 0 traps (ReleaseSafe) | chosen |
| libzstd 1.5.7 (`f8745da`, C) | BSD or GPLv2 | the reference | via `zig cc` | yes | the reference (OSS-Fuzz) | the baseline |
| pedronaugusto/warp, c4milo/stdx, baskingspot/compress | MIT | made 2026, 0 to 1 stars | warp yes, the others 0.16 | | | not measured (zaxified already reaches libzstd) |
| angt/unzstd | MIT | | | | | C, not Zig |

## 4. The new `hostlib/native/zstd.zig`

| Item | Before | After |
| --- | --- | --- |
| Decoder | `std.compress.zstd` | `hostlib/zstd` (zaxified, vendored, no changes), piece by piece API |
| Build mode of the decoder | ReleaseSmall (with hostlib) | ReleaseSafe (module `zstd_dec`), hostlib ReleaseSmall |
| Native API, error tags, handle table, OOM | | the same |
| Window limit | 8 MiB hard | the same |
| Stream buffer | window + slack (128 KB to 2 MB), the window moves down | window + 2 blocks + 64 B, a ring. It grows from 256 KB with the output (`R-Z11`), and the decoder history moves with it (`rebase`). |
| `decode` buffer | the output (the window costs nothing) | the same |
| Decoder state | 256 KB of stack | about 160 KB of heap, made at the first frame |
| Stack reserve of a zstd op (`stackNeed`) | 300 KB | 32 KB (6 KB measured) |
| Frame checksum | not checked (std panics) | checked: a wrong checksum is `bad_frame` |

### Corrupt input (`tagfuzz`, 30,000 damaged frames, each through `decode` and a stream, ReleaseSafe, leak check)

No trap, no leak. The answers compared with the old code:

| Answer | decode | stream |
| --- | --- | --- |
| Same error tag | 26,483 | 26,647 |
| Same bytes | 1,011 | 1,006 |
| old bytes, new `bad_frame` (most: the checksum is now checked) | 1,736 | 1,347 |
| old `bad_frame`, new bytes (`zstd -t` also takes them: std was too strict) | 579 | 578 |
| old `truncated`, new `bad_frame` (the new code sees the bad header or block before the end) | 185 | 184 |
| old `truncated`, new `window_too_large` or `unsupported` (the new code checks the header when it is whole, the old one waited for the first block) | | 212 |
| old `bad_frame`, new `window_too_large` or `unsupported` | | 22 |
| both bytes, other bytes (libzstd gives the new bytes, `difffuzz`) | 3 | 3 |
| other (old `bad_frame` or `output_limit`, new `truncated` or `bad_frame`) | 3 | 1 |

With `feed` (below) in the run too (8,000 damaged frames, random chunks and random `max`): `feed` gives the same bytes or the same error as the stream each time.

`difffuzz` (500,000 damaged frames, zaxified against libzstd, one-shot): 37,883 same bytes, 462,117 both an error, 0 differences.

## 5. Output in parts: `feed` (op 11, `Native.ZstdStream.feed!`)

Request of the Talon registry (slice 111, section 8): one push gives all the output of its chunk, so a chunk with a high ratio passes the 16 MiB push limit (64 MiB of zeros is 2,076 bytes packed). The piece by piece decoder makes the stop natural: the stream stops before the next unit when the output is at `max`, and keeps the rest.

| Item | Rule |
| --- | --- |
| Op | 11 `zstd_stream_feed`: u32 handle, u32 `max` (0: 16 MiB), the chunk. Out: at most `max` bytes, then one byte `more`. |
| Roc | `Native.ZstdStream.feed! : ZstdStream, List(U8), U64 => Try({ out : List(U8), more : Bool }, [...])`. The same error tags as `push!`, but never `OutputLimit`. |
| `more` | True: the stream has more output for the input so far. Call again with an empty chunk. False: give the next chunk. |
| What waits | The output of the last block that did not fit (it stays in the window buffer: no copy), and the input not read (a copy of the rest of the chunk). A chunk given while `more` is true is kept after it. |
| `close` | `truncated` when output or input still waits. |
| `push!` | No change. A stream can mix `push!` and `feed!`: a push first gives what waits. |

| Test | Result |
| --- | --- |
| R-Z15 (`native_test.zig`): 64 MiB of zeros in one chunk. `push`: `output_limit`. `feed` with 1 MiB: 64 MiB, the SHA-256 of the CLI, each part at most 1 MiB, peak memory at most 12 MiB (window 8 MiB) | PASS |
| R-Z15: `pkg.tar.zst`, `pkg-pipe.tar.zst`, `multi.zst` with chunks 1, 7, 4096, 65536 and `max` 7, 1000, 1 MiB give the bytes of `zstd -d` | PASS |
| R-Z15: `close` while output waits: `truncated`, the slot is free | PASS |
| `bench/native-test.mjs` `feed`: in the app, the push of the zeros chunk is `OutputLimit`; `feed!` with 1 MiB gives 67,108,864 bytes in 64 parts of 1 MiB (and one empty call), the SHA-256 of the CLI; `pkg-pipe.tar.zst` in parts of 4 KB | PASS |
