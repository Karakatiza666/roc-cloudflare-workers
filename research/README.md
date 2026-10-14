# Research code

Prototypes and measurements for PLAN.md. They are not part of the platform build.

| Folder | What | Used for |
|---|---|---|
| `alloc/` | Allocator versions v0 to v7, a harness, bench scripts (results in `alloc/README.md`) | Step 6e (B5), sums per task, one instance per isolate |
| `hash/` | Change-detection sums in wasm: Fletcher (SIMD), wyhash, XOR | The sum at each wait |
| `heap-options/` | Heap options H1 to H9 on a standalone harness | Heap optimization table in PLAN.md |
| `traps/` | V1 to V4 trap tests, wild-write test, on the v0 allocator with a walk sum | Clean and unclean traps |
| `workerd/` | workerd probes: TCP reset, request signal, JSPI stack, FinalizationRegistry, JS heap | The workerd facts in PLAN.md |

Only `alloc/` has a build script that works from this layout (`alloc/build.sh`). The other folders keep the sources as they ran: their paths point to a repo copy with `out/` and `bench/` beside the scripts.

## Results recorded here (measured 2026-10-14)

These are the numbers that PLAN.md uses from the folders with no README of their own. The raw output was not kept, so run the script again to check a number.

| PLAN.md | Result | Script |
|---|---|---|
| 3.0: does the I/O promise settle after a client reset? | No. After a TCP RST, the I/O promises and timers of the request never settle. | `workerd/q123.mjs`, `workerd/rawdrop.mjs`, `workerd/show.mjs` |
| 3.0: `request.signal` | Fires only with the compatibility flag `enable_request_signal` (set in `workerd/config3.capnp` and `config4.capnp`) | `workerd/q123.mjs`, `workerd/worker.js` |
| 3.0: suspended JSPI stacks | Never freed: about 6 KB of RSS and 1 MB of address space each | `workerd/massdrop.mjs`, `workerd/bigok.mjs` (control) |
| 3.0, M10: collection of a dropped 30 MB instance | 5.5 s with 64 requests at once, 20.1 s under memory pressure, not in 60 s when idle. Never with a suspended task. | `workerd/q5.mjs` |
| 3.0: JS heap of the shim, 64 requests at once | 46 MB in use, 76 MB committed | `workerd/q6.mjs` |
| 3.0, M4: cost of a call to JS and of a grow | Sync import call 6.2 ns, `memory.grow` of 1 page 281 ns | `workerd/q7.mjs` |
| Problem 12: sum speed | Fletcher with SIMD 66 GB/s, wyhash 12.5 GB/s. XOR misses swapped words. | `hash/run.mjs`, `hash/runc.mjs` (detection) |
| H9: grow step | 64 KB | `heap-options/growcost.mjs`, `heap-options/h9.jsonl` |
| V1 to V4 (problem 4) | See the V table in PLAN.md problem 4 | `traps/v1.mjs`, `traps/v1b.mjs`, `traps/v1c.mjs`, `traps/v4.mjs` |
