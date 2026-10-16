# Native ops: zstd, BLAKE3, SHA-256 (PLAN.md 8e)

This is the standalone Zig part of step 8e. It has no Roc and no bridge. The bridge (8a) calls it from `native!`. The spec is `API.md` 8 and the Test column of the 8e row in `PLAN.md`.

## 1. What is built

| File | Use |
| --- | --- |
| `hostlib/native/zstd.zig` | `decode` (one call, output limit) and `Stream` (push chunks), on `std.compress.zstd` |
| `hostlib/native/native.zig` | `call(allocator, owner, op, bytes)`: the ops, the handle table, `endTask` (the cleanup hook) |
| `hostlib/native/native_test.zig` | 25 tests. Run: `zig test hostlib/native/native_test.zig` from the repo root |
| `research/native/make-data.sh` | Makes the test data with the `zstd` CLI |
| `research/native/data/` | Test data. The `big-*` files are not committed (`make-data.sh`) |
| `research/native/harness/` | wasm32 harness with the real `hostlib/alloc.zig` (`build.sh`, `run.mjs`, `bench.mjs`, `sizes.sh`, `real.mjs`), a fuzz run (`fuzz.zig`), a file check (`check_files.zig`) |
| `research/native/revert-check.py` | Does each revert for real, runs the tests, restores the file |
| `research/native/env.sh` | `ZIG` and a cache directory in `research/native/.cache` |

No existing file is changed. The repo build is not used. A temporary edit of `hostlib/native/*.zig` by `revert-check.py` is always restored (the last run ended with the same files).

## 2. Ops

The op number is the `U32` of `native!`. The numbers are a proposal (`API.md` 8 gives none). All integers are little-endian.

| Op | Name | Bytes in | Bytes out (status 0) |
| --- | --- | --- | --- |
| 1 | `zstd_decode` | u32 `max_out`, then the frames | The output |
| 2 | `zstd_stream_open` | nothing, or u32 `window_limit`, or u32 `window_limit` and u32 `push_limit` (0 is the default) | u32 handle |
| 3 | `zstd_stream_push` | u32 handle, then a chunk | The output of the whole blocks in the chunk (can be empty) |
| 4 | `zstd_stream_close` | u32 handle | Nothing. Status 1 `truncated` when the input stopped inside a frame. The handle is freed in both cases. |
| 5 | `blake3_new` | nothing | u32 handle |
| 6 | `blake3_update` | u32 handle, then a chunk | Nothing |
| 7 | `blake3_final` | u32 handle | 32 bytes. The handle is freed. |
| 8, 9, 10 | `sha256_new`, `sha256_update`, `sha256_final` | as 5, 6, 7 | as 5, 6, 7 (32 bytes) |

A handle is `gen << 8 | (slot + 1)`. It is never 0. Treat it as an opaque `U32`.

### Status and codes

On status 1 the bytes are a short code (ASCII). Roc sees status 0 and 1. Status 4 stays in the host.

| Status | Code | Cause |
| --- | --- | --- |
| 1 | `output_limit` | The output is more than `max_out` (op 1), or more than `push_limit` in one push (op 3) |
| 1 | `window_too_large` | The frame header needs a window over the limit (stream only) |
| 1 | `bad_frame` | Not a zstd frame, or a damaged frame, or bytes after the last frame |
| 1 | `truncated` | The input is empty or stops inside a frame |
| 1 | `unsupported` | A frame with a dictionary |
| 1 | `bad_handle` | Closed handle, wrong number, or a handle that an old task made |
| 1 | `wrong_task` | The handle belongs to another task (PLAN.md 8e) |
| 1 | `wrong_kind` | The handle is a stream, a BLAKE3 state or a SHA-256 state, and the op wants another |
| 1 | `too_many_handles` | More than 16 handles for the task, or more than 4 streams, or no free slot (64 in the instance) |
| 1 | `no_task` | A handle op with owner 0 (the host) |
| 1 | `bad_argument` | Bytes too short, unknown op, or `window_limit` over 64 MiB |
| 4 | `out_of_memory` | The allocator gave 0. The bridge makes a clean OOM trap (`API.md` 4.1). |

The code text is a proposal for the human review (TW24).

## 3. Limits

| Limit | Value | Where |
| --- | --- | --- |
| Output of `zstd_decode` | `max_out`, a u32 of the caller. The decode stops after the block that passes it (at most 128 KB over), and a content size in the header over it stops before the first block. The result is an error, with no bytes. | `zstd.decode` |
| Window of `zstd_decode` | None. The buffer is the whole output, so the window costs no memory (section 4). | `zstd.decode` |
| Window of a stream | 8 MiB default (the size that the zstd standard tells all decoders to take). Hard limit 8 MiB (decided 2026-10-16; it was 64 MiB). A frame over it is `window_too_large`, and an open with a larger limit is `bad_argument`. | `WINDOW_DEFAULT`, `WINDOW_MAX` |
| Output of one push | 16 MiB default, or `push_limit`. One block (128 KB) can pass it. | `PUSH_DEFAULT` |
| Handles | 64 in the instance, 16 for a task, 4 zstd streams for a task | `native.zig` |
| Stack | About 274 KB while a block decodes (std keeps two 128 KB arrays on the stack). The task stack is 1 MB. | measured, section 7 |

## 4. How std zstd behaves

| Finding | Effect |
| --- | --- |
| It works on wasm32-freestanding with any `std.mem.Allocator` and needs nothing else. | The allocator of the task (`hostlib/alloc.zig`) is used for everything. |
| The reader wants the whole next unit (header and block) in its input. A short input is an error that cannot be resumed. | `Stream` reads the frame header and each block header itself (`probe`), and calls std only with a whole unit. A unit that does not fit in a chunk waits in a buffer of at most 128 KB. |
| The window buffer must be at least `window + 128 KB` (an assert), and std keeps the window with a `memmove` when the free space is under 128 KB. | The stream buffer starts at 256 KB and grows with the output up to `window + slack` (slack: a quarter of the window, from 128 KB to 2 MB, to make the `memmove` rare). A frame from a pipe says 8 MiB, and a small archive still takes a small buffer. |
| In one-shot mode std uses the window length as the "keep" length of its output writer. With a plain writer, any output would need a buffer of window size. | `decode` gives std only the header of each frame first (`Frame.init` sees the real window). Then it sets `window_len` to 0 and gives the rest. The buffer is the output. This uses internal behavior of std 0.17: test R-Z5 and the table in section 6 catch a change. |
| The frame checksum is not checked. `verify_checksum = true` panics ("TODO"). | The Roc code must check the archive with BLAKE3 (RN8). Damaged data can decode to other bytes: 5,889 of 80,000 damaged inputs of the fuzz run still decoded. |
| Dictionary frames are refused. | Code `unsupported`. |
| Skippable frames and many frames are fine. | The tests cover both. |
| It is slow (section 7). | 70 MB unpacked is about 1.2 s of CPU. |

Real packages: `data/roc-parser.tar.zst` is a bundle that `roc bundle` made (roc-parser): one frame, window 2 MiB, no content size, no checksum. All 44 `.tar.zst` files that other agents left in `~/.claude/jobs/*/tmp` (Roc packages, 154 B to 27.7 MiB, all with a window of 2 MiB or less) and the files of `data/` give the same bytes as `zstd -d` with `decode` and with the stream in chunks of 1000 bytes (`harness/check_files.zig`). The biggest is a basic-cli package: 27.7 MiB packed, 95.5 MB unpacked, window 2 MiB, no checksum. In wasm32 (`harness/real.mjs`) the stream decodes it in 2.0 s (48 MB/s) with a peak of 4.8 MB, and the SHA-256 equals the CLI. The files are not copied into the repo (only `roc-parser.tar.zst` is). The files made with `zstd --ultra -22` have a 128 MiB window: a stream refuses them, and an isolate of 128 MB could not hold that window.

## 5. Tests

Run from the repo root: `source research/native/env.sh; $ZIG test hostlib/native/native_test.zig --cache-dir research/native/.cache/local`. For wasm32: `research/native/harness/build.sh`, then `node research/native/harness/run.mjs [native-fast.wasm]`.

The test ids (R-Z, R-H, R-N, W) are local to this folder. The expected bytes come from the `zstd` CLI (v1.5.7), `sha256sum`, and the Python package `blake3` 1.0.11 (PyPI). `b3sum` is not installed. The Python package is the official binding. `hashes.txt` holds the digests. The empty-input digest is also the vector of the BLAKE3 spec.

| Id | Test (zig test) | PLAN.md 8e | Result |
| --- | --- | --- | --- |
| R-Z1 | `zstd_decode` of 4 variants of a real package equals `zstd -d`: file input (content size, checksum), pipe (8 MiB window), no checksum, 16 MiB window. Also `roc bundle` output, in one piece and in chunks | decode a package | PASS |
| R-Z2 | Two frames with a skippable frame between them | | PASS |
| R-Z3 | The limit is exact: `max_out` = size is ok, size - 1 and 0 are `output_limit` | stops at the limit | PASS |
| R-Z4 | A 149 byte archive that decodes to 4 MB, limit 256 KB: `output_limit`, no leak, peak memory at most 2 (limit + 128 KB). With and with no content size in the header. | stops at the limit, memory | PASS |
| R-Z5 | The window of the frame (8 and 16 MiB) is not allocated: peak under 512 KB | | PASS |
| R-Z6 | Empty, cut, bad and trailing bytes give `truncated` and `bad_frame` | | PASS |
| R-Z7 | 300 damaged inputs: no trap (Debug safety checks) | | PASS |
| R-Z8 | Stream with chunks of 1, 7, 4096 and 65536 gives the same bytes (3 variants, 2 frames with a skippable frame) | chunk sizes | PASS |
| R-Z9 | Stream of a 10 MB archive (window 8 MiB, output 33.5 MB, so the window moves many times): SHA-256 equals the CLI | | PASS |
| R-Z10 | Window limit: 16 MiB frame refused with the default, accepted with 16 MiB. Over 64 MiB is `bad_argument`. | | PASS |
| R-Z11 | A small output from an 8 MiB window frame: stream peak under 1 MB | | PASS |
| R-Z12 | `push_limit`: `output_limit`, peak under 1.5 MB, the stream stays dead, `close` frees it | | PASS |
| R-Z13, R-Z14 | Cut, bad and damaged input in the stream (100 damaged inputs, random chunks) | | PASS |
| R-H1, R-H2 | BLAKE3 and SHA-256 of 4 files (123 KB, 246 KB, 200,001 B, empty) in chunks of 64 KB, 1000 B, 1 B and one piece equal the references | BLAKE3 equals `b3sum` | PASS |
| R-N1 | A handle of another task gives status 1 `wrong_task` (update, final, push, close). The owner can still use it. | status 1 | PASS |
| R-N2 | Closed handle, wrong kind, wild numbers, a reused slot with a new generation | | PASS |
| R-N3 | `endTask` drops only the handles of the task, and with `.free` its blocks (the leak check of `std.testing.allocator`) | | PASS |
| R-N4 | 16 handles and 4 streams for a task, and another task is not stopped | | PASS |
| R-N5 | A failing allocation at each step of each handle op: status 4, no leak, no slot that points at freed memory | | PASS |
| R-N6 | Owner 0 gets no handle | | PASS |
| W1 to W6 | The same checks in wasm32 with the real allocator (`run.mjs`): bytes, limit and peak memory, other task, chunks, digests, and the end of a task by trap and by return (memory back to the start value, `checkTables` 0, no foreign free, the handles of the other task live) | | PASS, small and fast build |

Other runs: the tests also pass with `-O ReleaseSafe` and `-O ReleaseFast`. `harness/fuzz.zig` (`-O ReleaseSafe`, 80,000 damaged inputs through `decode` and the stream, 4 files): no panic and no leak.

## 6. Revert checks

Each row is a real edit of the source, a run, and a restore (`python3 research/native/revert-check.py`). "Node" is the wasm32 build with the edit, run with `run.mjs`.

| Revert | Tests | zig test | Node |
| --- | --- | --- | --- |
| No output limit in `decode` (limit 1 GB) | R-Z3, R-Z4, W2 | FAIL | FAIL, 4 checks: peak memory 4.2 MB (the whole output) against 0.2 KB and 384 KB with the limit |
| No `window_len = 0` after the header | R-Z5 | FAIL | |
| No owner check in `lookup` | R-N1, W3 | FAIL | FAIL, 3 checks |
| No generation check in `lookup` | R-N2 | FAIL | |
| No owner 0 check in `insert` | R-N6 | FAIL | |
| No per-task cap | R-N4 | FAIL | |
| `endTask` does not free the blocks | R-N3 | FAIL (leak) | |
| `endTask` does not drop the slots | R-N3, W6 | FAIL | FAIL, 2 checks |
| The start of a unit is dropped at a chunk end | R-Z8, W4 | FAIL | FAIL, 2 checks |
| The stream buffer starts at the full window | R-Z11 | FAIL | |
| No `push_limit` check | R-Z12 | FAIL | |
| No window limit check | R-Z10 | FAIL | |
| BLAKE3 and SHA-256 state is reset at each update | R-H1, R-H2, W5 | FAIL | FAIL, 7 checks |
| The slot is made before the result block (a failed allocation leaves a slot) | R-N5 | FAIL | |

After each restore the tests pass again. The R-N5 revert is a bug that the first version had: the OOM test found it as a crash.

## 7. Speed, memory, size

Node v26.7, V8 wasm, one instance, real `hostlib/alloc.zig`, 128 MB budget. Data: the start of a binary in a tar, `zstd -19` (ratio 3.6 to 3.7, as a platform archive). Best of 3. Noise: about 15 percent between runs. "Small" is ReleaseSmall as the production host. "Fast" is ReleaseFast.

| Op | In | Out | Small: MB/s out | Fast: MB/s out |
| --- | --- | --- | --- | --- |
| `zstd_decode`, 1 MB `.tar.zst` | 1.03 MB | 3.7 MB | 61 to 76 | 79 to 84 |
| `zstd_decode`, 10 MB `.tar.zst` | 9.99 MB | 33.5 MB | 54 to 58 | 62 |
| stream, 10 MB, pushes of 64 KB | 9.99 MB | 33.5 MB | 55 | 56 to 59 |
| `blake3_update`, 64 KB chunks | 164 MB | | 950 to 1,009 in | 1,694 to 1,800 in |
| `sha256_update`, 64 KB chunks | 164 MB | | 345 to 384 in | 373 to 422 in |

For comparison: the same `decode` as native Zig (ReleaseFast) gives 70 MB/s. The `zstd -d` CLI takes 93 ms for the 10 MB file (about 360 MB/s). So the std decoder is slow on any target, and wasm is about 20 percent slower than native. The wasm hashes are fast: BLAKE3 uses simd128.

| Memory | Value |
| --- | --- |
| `zstd_decode`, 10 MB archive, 33.5 MB out | peak live 32.8 MB (the output) plus the input. A frame with no content size has the same peak, because the allocator grows the large block in place. |
| `zstd_decode`, 1 MB archive, 3.7 MB out | peak live 3.7 MB |
| stream, 10 MB archive, pushes of 64 KB | peak live 13.1 MB: window 8 MiB, slack 2 MB, one push of at most 1 MB, a pending block |
| stream, 1 MB archive | peak live 6.5 MB (the window is the whole output) |
| Stack | 274 KB (zstd), 14 KB (BLAKE3), 9 KB (SHA-256) |
| BLAKE3 and SHA-256 state | 1,920 B and 112 B for each handle |

| Size of the harness wasm | Small (B) | Fast (B) |
| --- | --- | --- |
| Allocator only | 20,330 | 65,288 |
| With all ops | 101,049 | 664,271 |
| So Native adds | 80.7 KB | 599 KB |

An archive of 21 MB packed and 70 MB unpacked (basic-cli, `RF5`) does not fit in one call: input 21 MB, output 70 MB and the copy into a Roc list 70 MB is 161 MB. Use the stream. The rest of the work (tar) reads each push.

## 8. Integration steps for `native!` (8a)

Done in 8e (2026-10-16): see "Status of step 8e" in `PLAN.md`. The op table is in `API.md` 8. Two differences from the code below: `roc_native` calls `canary.reserve(native.stackNeed(op))` first (decision 3: a clean trap when the stack is short), and `Bytes.items()` gives the input slice.

`native!` takes `U32, List(U8)` and gives `{ status : U8, bytes : List(U8) }`. No `Js` value crosses it. The typed `Native` module (`MODULES.md`) builds the bytes of the table in section 2 and turns status 1 into `Err(code)`. The stub is `roc_native` in `host/host.zig`.

| Step | Where | What |
| --- | --- | --- |
| 1 | `hostlib/root.zig` | Add `pub const native = @import("native/native.zig");`. The files are in the `hostlib` module directory, so `build.zig` does not change. They use only `std`. |
| 2 | `host/host.zig`, `roc_native` | See the code below. The owner is `lib.alloc.OWNER` (the task that runs). The allocator is `lib.alloc.allocator`, which tags each block with `OWNER`. |
| 3 | `hostlib/alloc.zig`, `taskEnd` | First line after `if (owner == 0) return 0;` (before `taskFind`): `@import("native/native.zig").endTask(allocator, owner, .forget);`. Every end of a task goes through `taskEnd`: a normal end (`taskDone` in `handle`), a trap (`freeOwner` in `abortFree`), a cancel and the abort of a waiting task (`freeOwner` in `waitDrop`). `.forget` only drops the slots. The blocks are of the task, so the allocator frees them in the same call. |
| 4 | `platform/Host.roc` and the `Native` module | `native!` stays `U32, List(U8) => { status : U8, bytes : List(U8) }`. Roc writes the u32 with `List.concat`, little-endian. A handle is an opaque `U32`. |
| 5 | Tests of 8a | An end of a task with a handle open must show live bytes 0, as W6 does (`h_end_trap` and `h_end_done` in `harness/harness.zig` are the model). |

Step 2 code (names of the Roc list helpers are those of `host.zig`):

```zig
export fn roc_native(op: u32, bytes: Bytes) callconv(.c) abi.HostNative {
    const in: []const u8 = if (bytes.length == 0) &.{} else @as([*]const u8, @ptrCast(bytes.elements_ptr.?))[0..bytes.length];
    const a = lib.alloc.allocator;
    const r = lib.native.call(a, lib.alloc.OWNER, op, in);
    defer r.release(a); // frees the result block (owned only for status 0 with bytes)
    bytes.decref(ROC_HOST); // after the call: `in` points into the list
    if (r.status == 4) lib.cpu.oom(); // a clean OOM trap, as a failed roc_alloc
    // Copy `r.bytes` into a new List(U8) of the task (a host made list, as the others). status is 0 or 1.
    return .{ .bytes = listFromSlice(r.bytes), .status = r.status };
}
```

| Rule | Reason |
| --- | --- |
| Call `native.call` only while a task runs (`OWNER` is not 0). | A handle of owner 0 is refused (`no_task`), because nothing would free it. |
| A task that never closes a handle needs no code in Roc. | `endTask` and the allocator free it at the end of the task (W6). |
| The table is global in the instance, and the key is the task id. JS never reuses an id. | Tasks that run at the same time do not see each other's handles (R-N1). |
| `native.call` never waits and never calls JS. | No stack copy is needed. |
| The result is a copy. | The one-shot output is held twice for a moment. See the open question on the copy. |

## 9. Open questions

| # | Question | Now |
| --- | --- | --- |
| 1 | Which window do real packages have? `roc bundle` gives 2 MiB. `zstd -19` from a pipe gives 8 MiB. `--ultra -22` gives 128 MiB. What does `tln publish` use? | Stream default 8 MiB, hard limit 64 MiB. A 128 MiB window cannot work in an isolate of 128 MB. `zstd_decode` has no window limit. |
| 2 | Should the zstd frame checksum be checked? | Not checked (std panics on `verify_checksum`). The registry hashes the asset with BLAKE3. An xxh64 check is about 20 lines (`std.hash.XxHash64`). |
| 3 | The stack use of 274 KB inside a 1 MB task stack: is it enough for a deep Roc call that calls `native!`? | Not measured with a deep app. A copy of the std decoder with heap buffers would remove it. |
| 4 | The std decoder is slow (about 55 MB/s). Is that enough? | 70 MB unpacked is about 1.2 s of CPU. A faster decoder needs libzstd in C. Not done: the task asked for Zig `std`. |
| 5 | Build the native code with ReleaseFast? | The host builds `hostlib` as ReleaseSmall. ReleaseFast gives 1.1 to 1.3x on zstd and 1.8x on BLAKE3, and adds about 520 KB over ReleaseSmall. It can be a separate module. |
| 6 | The op numbers, the codes, the extra u32 `push_limit` of `zstd_stream_open`, and the caps (16 handles, 4 streams, 64 slots) | Proposals. `API.md` 8 gives only the op names and the window limit. |
| 7 | A stream that failed stays open until `close` or the end of the task. | `close` on a failed stream gives the error and frees it. |
| 8 | The result copy into a Roc list. A call that makes the block as a Roc list would save one copy of the output. | Not done. It needs the list layout of the allocator (`bytesFrom` in `host.zig`). |
| 9 | `max_out` is a u32, so one `zstd_decode` gives at most 4 GB. | The isolate has 128 MB. |


Decisions (manager, 2026-10-16):

| # | Decision |
| --- | --- |
| 1 | Hard stream window 8 MiB. `roc bundle` and the 44 packages seen use 2 MiB or less; `zstd -19` from a pipe uses 8 MiB. Test R-Z10 checks it; a revert to 64 MiB fails it. |
| 2 | No frame checksum. The registry checks the BLAKE3 of the asset. |
| 3 | The 274 KB of stack stays for now. The 8a integration adds a test: a deep Roc call that then calls `native!` with `zstd_decode` gives a clean trap or a result, never damage. A copy with heap buffers comes only if that test fails. |
| 4 | ReleaseSmall stays. 8g measures the ingest on wasm32 and decides on a ReleaseFast module. |
| 5 to 9 | The op numbers, codes, caps and `push_limit` above are accepted. The 8a integration writes them into API.md 8. |
