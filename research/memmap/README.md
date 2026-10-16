# Memory map of an instance (PLAN step 12-pre)

Goal: show where each byte of one instance is, who writes it, and which bytes do not change after `init`. The result is the input for 12a (the sum at wait) and 12d (the global check).

Result in short: every region of the bench app is in a row of the PLAN 12 table "What a host bug can damage", with 3 exceptions (see "Not in the table"). Only 5.2 KB of the 2.2 MB of static memory is constant after `init`.

## Files

| File | Use |
|---|---|
| `memmap.mjs` | The script: `node research/memmap/memmap.mjs <app.wasm> [--map f] [--kind app\|deep] [--light] [--detail] [--json]` |
| `build.sh` | Builds `app`, `app_deep` and `app_boxy` in a copy of the repo (`.work/`, git ignores it) and writes `out/<name>.wasm` and `out/<name>.map`. It does not touch the tree. |
| `wasm/` | Copies of `bench/out/app.wasm` and `app_deep.wasm` from the start of the work. They have no map: coarse run only (`results/copy_*`). |
| `results/` | The full output of the runs in this file (`--detail`: one row for each data symbol) |

`app_boxy` is `bench/app.roc` built with `roc build --specialize=no`. It links the roc boxy runtime, so it has foreign units. The bench apps do not (they use the default lowering).

## Run

```
research/memmap/build.sh                                        # needs ZIG and ROC (see CLAUDE.md of the repo)
node research/memmap/memmap.mjs research/memmap/out/app.wasm
node research/memmap/memmap.mjs research/memmap/out/app_deep.wasm
node research/memmap/memmap.mjs research/memmap/out/app_boxy.wasm --light   # slow build: small requests
```

Exit 0: each region is in a row, and no constant region was written. Exit 1: not. Exit 2: usage, or the map does not match the wasm.

## Method

| Step | What |
|---|---|
| 1 | Parse the wasm: memory limits, the start of `__stack_pointer` (the top of the shared stack), data segments, name section. The production link has no name section (roc runs `wasm-ld --strip-all`). |
| 2 | Symbol addresses come from the wasm-ld map. Roc does not write one, so `build.sh` runs the same link again with `-Map`. The script checks the map: each data segment is inside the map, and at the mapped addresses `STACK_LIMIT - CANARY_BASE` is 4096. |
| 3 | Make the instance with the stub `env.js_wait` of `bench/core.js` (copied into the script, no import from `bench/`). Call `set_free_mark`, then `init(1)`. Copy the static memory (below the pool). |
| 4 | Run the request mix (next table). After each phase compare the static memory with the copy after `init`. Each changed byte keeps the first phase that changed it. |
| 5 | Read the heap from the unit tables (`U_KIND`, `U_SLOT`, `U_UNITS`, `FREE_BITS`, `CACHE`): free, reserve, small and large units by owner (host slot 0, JS slot, task slots), foreign. The `Wait` records (`host.WAITS`) give the saved stack copies. |
| 6 | Cut the static memory into regions with no gap. A rule on the symbol name (`RULES` in the script) gives each region its PLAN 12 row. A region with no row is a finding. |

Request mix of the bench app (`app_deep` has its own, same shape):

| Phase | What |
|---|---|
| one request, seq 1 to 4 | A request alone, then 4 more one after another |
| many | 64 at once (items 200, every 8th 2,000, every 16th depth 400). A snapshot when all 64 wait. |
| faults | 24 at once: 4 traps after the first wait, 2 `dbg` requests (200 log lines, then a crash), 3 cancels while they wait (status 5), then `fail_next_alloc` (a clean OOM trap) |
| idle | `log_clear`, no task. Snapshot. |
| bench exports | `heap_fill` (the `FILL` table, bench only) |
| unclean traps | `fault_next_wait` 1, 2, 3: an out-of-bounds write, `unreachable`, a wrapped stack pointer. `task_abort` gives -1. |
| `app_deep` only | stack overflow: depth 100,000 without and with an allocation (V1) |

Limit: "written" means that a byte differs at a snapshot (after each phase, and when all tasks wait). A write that is undone before the next snapshot is not seen. For the constant data this is enough, because 12d also compares at a point in time.

Test of the script (the checks must fail when the data is bad):

| Change | Result |
|---|---|
| Normal run on `app_deep` | exit 0, "every region is in a row" |
| `MEMMAP_WILD=0x100010` (flip one byte in the constant data after the first request) | exit 1, "constant region written: rodata (host)" |
| `MEMMAP_WILD=0x2150a8` (a byte in the unused tail) on `app` | exit 1, "unused tail of the initial memory (padding, written)" |
| Rule for `host.WAITS` removed from `RULES` | exit 1, "host statics (.bss)" has no row |
| `--map out/app_deep.map` on `app.wasm` | The map is ignored (its sections do not fit the data segments): coarse run, exit 1 |
| `--map out/app_boxy.map` on `app.wasm` | exit 2, "the map does not match this wasm" (canary check) |

## Result by PLAN 12 row (bench app, 2026-10-16 build)

Static memory at start: 34 pages, 2,228,224 B. The pool (heap units of 4 KB) starts at 0x220000, right after it. After `init` the pool has 0 units.

| PLAN 12 row | What the script found | Size | Written after init | Constant |
|---|---|---|---|---|
| 1 Task pages and large blocks | Heap units of the task slots. Peak with 64 tasks (2,000 items for 8 of them): 144 small pages, 2,800 units in large blocks | 12.1 MB at the peak | Yes (all new) | No |
| 2 Saved stack copy | 64 copies inside the task units, found with the `Wait` records | 2,025,216 B at the peak | Yes | No |
| 3 Wait record | 64 records of 32 B in one host page (slot 0) | 2 KB | Yes | No |
| 4 Shared stack | Guard 0x000000 to 0x002000, stack 0x003000 to 0x100000. Used part (app): from 0x0d6f14 up, 169 KB | 1,044,480 B | Yes | No |
| 5 Free units, reserve | Free units, up to 256 reserve pages, and the unused tail of the initial memory (0x2150a0 to 0x220000, 44,896 B) | n/a | Tail: no | n/a |
| 6 Allocator tables, task records, reserve table | 14 unit tables (`U_*`), free-run index, pool bounds, `CACHE`, `TASKS`, `SLOT_OWNER` | 870,176 B | about 10,200 B changed (varies by 1 % between runs) | No |
| 7 Constant data | `.rodata` of host and Roc, host tables (`vtable`, `host`), canary (4 KB) | 5,188 B | 0 B changed | Yes |
| 8 Host globals | Counters, flags, `LOG`, `OWNER`, `TASK_*`, `WAITS`, canary globals, `FREE_MARK` | 1,112 B | 272 B changed | Only `FREE_MARK` and the canary globals (16 B) |
| 9 Foreign units | None in `app` and `app_deep`. In `app_boxy`: 896 units (3.67 MB) | 0 or 3.67 MB | Yes | 805 of 896 units |
| 10 JS blocks | JS pages (slot 255): request and response blocks | 1 unit at the peak | Yes | No |

## Not in the table

| Region | Size | Written by | Why it matters | Proposal |
|---|---|---|---|---|
| Response block: a host block (owner 0) that `handleImpl` makes. It lives from the return of `handle` until `res_free`. JS reads it. | 4 + body length | `handleImpl` | Seen: 1 host unit exists in that window, and no sum covers it. Other tasks run in the window. | Add it to row 8 or row 10, or sum it at the return of `handle` and check it in `res_free`. The window is short. |
| Roc code statics `roc_tail_pending` (4 B) and `roc_tail_args` (208 B in `app`; not in `app_deep`) | 212 B | Roc code of the running task (the tail-call driver) | Mutable, in no table. The args look live only inside one call, never across a wait. To confirm in `roc:src/backend/llvm/MonoLlvmCodeGen.zig:2100`. | A row "Roc code statics: no check, never live across a wait" |
| Roc runtime statics (`app_boxy` only): `TailStateSelection.state`, `boxy_abi.global`, `main.initialized`, `heap.BrkAllocator.global` | 352 B, 66 B changed | The roc boxy runtime | Mutable, live across waits | A row, with a range check or a sum |
| Bench only (not in a production build, PLAN 7a) | `FILL`, `FILLED`, `FILL_TAG` 262,152 B, `FAULT_NEXT` 4 B | Bench exports | None | None |

`WAITS` (1 KB of pointers to `Wait` records) and the other host counters are in row 8 by this script's rule. The PLAN says "task ids" there. Confirm.

## Findings for 12a and 12d

| Finding | Effect |
|---|---|
| The constant static data is 5,188 B (app) and 4,633 B (app_deep). 4,096 B of it is the canary. | The sum at `init` is tiny. 12d cost: below 1 µs. |
| Constant ranges (app): 0x100000 to 0x100404 (`.rodata` and `FREE_MARK`), 0x103810 to 0x103850 (host tables), 0x103860 to 0x10386c (canary globals), the canary 0x002000 to 0x003000. | 12d takes the ranges from symbols (the start of the data, `FREE_MARK`, `alloc.vtable`, `roc.RocHostOf.host`, `CANARY_BASE`), not from fixed addresses. They change with each build. |
| `FREE_MARK` is constant only when JS calls `set_free_mark` before `init` (as `bench/core.js` does). | The sum at `init` must be taken after both calls. |
| Row 8: only 16 B are constant. The rest changes by design (`LOG`, `TRAP_CLEAN`, `OWNER`, counters). | Range check, not a sum |
| The unit tables are 870,176 B. A mix of 64 tasks changed about 10,200 B. | A structural check can read only the used part (`POOL_LO` to `POOL_HI`) |
| `Wait` is a Zig struct with no `extern`. The script found the order low, top, copy pointer, copy length, out (2 words), owner, at (32 B) in all records. | 12a: make `Wait` an `extern struct`, or the order of the sum can change with the compiler |
| `host.WAITS`: each entry is null or points to a record with `at` = the index and `top - low` = the copy length. | Range checks for 12d: `TASK_WAITING` = number of entries, `TASK_SAVED` = sum of the copy lengths |
| The stack guard (0 to 0x2000) gets written in an overflow (102 B in `app_deep`). The canary is written again by `repair`. | Row 4: no check. 12d can check the canary only when no overflow is in progress. |
| Foreign units (`app_boxy`) are not set at `init`. 0 after `init`, 416 after the first request (20 items), 896 after 16 requests at once. At the first request: 400 units for 5 items, 416 for 20, 768 for 100. They stay at the high-water mark. | "Sum at init" does not fit them. See the questions. |
| 91 of 896 foreign units change after they are first seen: mostly the first 4 KB of each 64 KB block (47 runs of constant and changed units). | A sum of the other 805 units is possible: 3,297,280 B, about 50 µs at 66 GB/s |
| `app_boxy` also has a constant data blob of 826,296 B (`roc_boxy_sidecar_blob`), in its own output section after `.data`. | Constant. Sum at init, about 12 µs |
| Memory taken by the roc runtime before the first allocator call would be below `POOL_LO` and not marked foreign. Not seen: `poolInit` runs at the first `js_alloc`. | Keep the order: JS calls `js_alloc` before the first Roc code. A test in 12d. |

## Questions for 12a and 12d

| # | Question | For |
|---|---|---|
| 1 | Is the response block (host block between `handle` and `res_free`) a row? Which check? | 12b |
| 2 | Is `roc_tail_args` never live across a wait? (Roc compiler source, to confirm.) If yes, add the row "Roc code statics, no check". | 12d |
| 3 | Will talon use the boxy runtime (`--specialize=no`)? If not, rows 9 and the runtime statics are empty and 12d can skip them. | 12d |
| 4 | With the boxy runtime: the foreign units grow with the request size and are not set at `init`. When does 12d sum them (at marking, in `poolGrow`, is late: the runtime already wrote)? How does it skip the 91 units that change? | 12d |
| 5 | Is `WAITS` a row 8 item ("task ids")? | PLAN text |
| 6 | The unit tables are 870 KB in an instance of 2.2 MB at start. A lower `MAX_UNITS` for the fallback is already an option (M9). Is a smaller table wanted for production? | 6e, M9 |

## Output: bench app (`out/app.wasm`)

| Item | Value |
|---|---|
| File | out/app.wasm, 56,581 B, sha256 3b1a7e320e77eba3 |
| Request mix | app: one request, seq 1, seq 2, seq 3, seq 4, many, all waiting, many, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed, unclean trap 1, unclean trap 2, unclean trap 3 |
| Map check | ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses) |
| Symbols | out/app.map (83 data symbols); name section: 0 function names, 0 data names |
| Memory at start | 34 pages (2,228,224 B), maximum none; at the end 14,876,672 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 83, cancelled (status 5): 3, trap, clean: 7, trap, NOT clean: 3 |
| After the unclean traps | live bytes 177168, canary ok 1 (the pages of an unclean task stay: the instance is replaced in production) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 400 |

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack, guard below the canary | 0x000000 | 0x002000 | 8,192 | no | 0 | 4. Shared stack |
| stack canary (4 KB, written by init) | 0x002000 | 0x003000 | 4,096 | no | 4096 | 7. Constant data (host constant) |
| shared stack | 0x003000 | 0x100000 | 1,036,288 | yes: 39,601 of 1,036,288 B, 0x0d6f14 to 0x0ffffc; first in "one request" | 6 | 4. Shared stack |
| rodata (host), rodata (roc) | 0x100000 | 0x100400 | 1,024 | no | 0 | 7. Constant data |
| free mark (set once) | 0x100400 | 0x100404 | 4 | no | 4 | 8. Host globals |
| task records | 0x100404 | 0x103810 | 13,324 | yes: 722 of 13,324 B, 0x100408 to 0x1037f4; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| rodata (host), roc host table | 0x103810 | 0x103850 | 64 | no | 0 | 7. Constant data |
| allocator globals, counters, log | 0x103850 | 0x103860 | 16 | no | 0 | 8. Host globals |
| canary globals (init only) | 0x103860 | 0x10386c | 12 | no | 3 | 8. Host globals |
| allocator globals, counters | 0x10386c | 0x103874 | 8 | yes: 3 of 8 B, 0x103870 to 0x103873; first in "many, all waiting" | 0 | 8. Host globals |
| pool bounds, unit tables (U_*), page reserve table, free-run index | 0x103874 | 0x18caa0 | 561,708 | yes: 8,445 of 561,708 B, 0x103874 to 0x17e442; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x18caa0 | 0x18caa4 | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), task records, free-run index | 0x18caa4 | 0x1d4b8c | 295,144 | yes: 1,061 of 295,144 B, 0x18cee4 to 0x1d4b12; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| trap flag | 0x1d4b8c | 0x1d4b90 | 4 | no | 0 | 8. Host globals |
| allocator globals, counters, host globals | 0x1d4b90 | 0x1d4bb0 | 32 | yes: 15 of 32 B, 0x1d4b94 to 0x1d4bad; first in "one request" | 1 | 8. Host globals |
| bench only: heap_fill | 0x1d4bb0 | 0x214bb8 | 262,152 | yes: 2,753 of 262,152 B, 0x1d4bb0 to 0x1d5b57; first in "bench: heap_fill" | 0 | none (bench only) |
| WAITS (pointers to Wait records) | 0x214bb8 | 0x214fb8 | 1,024 | yes: 253 of 1,024 B, 0x214be1 to 0x214e3f; first in "many, all waiting" | 0 | 8. Host globals |
| host globals | 0x214fb8 | 0x214fbc | 4 | no | 0 | 8. Host globals |
| bench only: fault_next_wait | 0x214fbc | 0x214fc0 | 4 | no | 0 | none (bench only) |
| host globals | 0x214fc0 | 0x214fc4 | 4 | yes: 1 of 4 B, 0x214fc0 to 0x214fc1; first in "one request" | 0 | 8. Host globals |
| roc host table | 0x214fc4 | 0x214fc8 | 4 | no | 0 | 7. Constant data |
| Roc side statics (.bss) | 0x214fc8 | 0x2150a0 | 216 | yes: 52 of 216 B, 0x214fd0 to 0x21508c; first in "one request" | 0 | NONE |
| unused tail of the initial memory | 0x2150a0 | 0x220000 | 44,896 | no | 0 | 5 (nobody writes it) |

## Heap (units of 4 KB, read from the unit tables)

Pool at the end: 0x220000 to 0xe30000 (12,648,448 B). Counts are from the snapshot with 64 tasks waiting; "At idle" is the last snapshot with no task.

| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |
|---|---|---|---|---|---|---|
| free units | 0xced000 | 0xe2a000 | 19 | 77,824 | 2832 | 5. Free units, page reserve |
| page reserve (empty small pages) | 0x220000 | 0xcd1000 | 123 | 503,808 | 256 | 5. Free units, page reserve |
| task small pages (64 task slots) | 0x222000 | 0xccf000 | 144 | 589,824 | 0 | 1. Task pages and large blocks |
| task large blocks (2,025,216 B of it are 64 saved stack copies (row 2), found by the Wait records) | 0x23c000 | 0xe30000 | 2,800 | 11,468,800 | 0 | 1. Task pages and large blocks |
| host pages (slot 0) (Wait records (64 x 32 B), log lines; the response block is here for a short time) | 0x2ca000 | 0x2cb000 | 1 | 4,096 | 0 | 3. Wait record |
| JS pages (slot JS) (request blocks and response blocks of js_alloc) | 0x223000 | 0x224000 | 1 | 4,096 | 0 | 10. JS blocks |
| foreign units (roc runtime) | - | - | 0 | 0 | 0 | 9. Pages of the roc runtime (foreign units) |
| unit of kind none, not free, not reserve | - | - | 0 | 0 | 0 | none (empty) |

After init the pool has 0 units: every unit of the heap is written after init (nothing of the heap is constant from init). Wait record layout (low, top, copy ptr, copy len, out, owner, at): checked for all records (top - low = copy length, index = slot).

Host pages (slot 0) when the response block of the first request exists (between `handle` and `res_free`): 1 units, with 0 JS units. After that request: 0 host units.

| Foreign units | Value |
|---|---|
| After init | 0 |
| At the peak, at idle | 0, 0 |
| First seen in the snapshot | never |
| Units by snapshot | init: 0; one request: 0; seq 1: 0; seq 2: 0; seq 3: 0; seq 4: 0; many, all waiting: 0; many: 0; faults, all waiting: 0; faults: 0; idle: 0; after bench: 0; unclean trap 1: 0; unclean trap 2: 0; unclean trap 3: 0 |
| Changed after the first snapshot that has them | 0 of 0 units |

## Constant after init

Ranges that only `init` (or `set_free_mark`, called before it) writes, and that no request changed. Neighbors are joined. 12d sums these after init.

| Range | Size B | What |
|---|---|---|
| 0x002000 to 0x003000 | 4,096 | stack canary (4 KB, written by init) |
| 0x100000 to 0x100404 | 1,028 | rodata (host), rodata (roc), free mark (set once) |
| 0x103810 to 0x103850 | 64 | rodata (host), roc host table |
| 0x103860 to 0x10386c | 12 | canary globals (init only) |
| 0x214fc4 to 0x214fc8 | 4 | roc host table |
| Total, static | 5,204 | |
| Constant foreign units (unchanged after first seen) | 0 | 0 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| task records | yes: 722 of 13,324 B, 0x100408 to 0x1037f4 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| allocator globals, counters | yes: 3 of 8 B, 0x103870 to 0x103873 | 8. Host globals | range check (12d) |
| pool bounds, unit tables (U_*), page reserve table, free-run index | yes: 8,445 of 561,708 B, 0x103874 to 0x17e442 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), task records, free-run index | yes: 1,061 of 295,144 B, 0x18cee4 to 0x1d4b12 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| allocator globals, counters, host globals | yes: 15 of 32 B, 0x1d4b94 to 0x1d4bad | 8. Host globals | range check (12d) |
| WAITS (pointers to Wait records) | yes: 253 of 1,024 B, 0x214be1 to 0x214e3f | 8. Host globals | range check (12d) |
| host globals | yes: 1 of 4 B, 0x214fc0 to 0x214fc1 | 8. Host globals | range check (12d) |
| Roc side statics (.bss) | yes: 52 of 216 B, 0x214fd0 to 0x21508c | NONE | NONE |

### Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | Roc side statics (.bss) |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: 1 region(s) are not in the table.

## Output: `app_deep` (`out/app_deep.wasm`)

Same layout as `app`: no `roc_tail_*` statics, no foreign units. The overflow phases write 102 B into the stack guard.

| Item | Value |
|---|---|
| File | out/app_deep.wasm, 23,474 B, sha256 e25f310d7c4ad71a |
| Request mix | app_deep: one request, many, all waiting, many, overflow, no alloc, overflow, alloc, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed, unclean trap 1, unclean trap 2, unclean trap 3 |
| Map check | ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses) |
| Symbols | out/app_deep.map (67 data symbols); name section: 0 function names, 0 data names |
| Memory at start | 34 pages (2,228,224 B), maximum none; at the end 2,555,904 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 77, trap, clean: 3, cancelled (status 5): 3, trap, NOT clean: 3 |
| After the unclean traps | live bytes 0, canary ok 1 (the pages of an unclean task stay: the instance is replaced in production) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 0 |

## Constant after init

Ranges that only `init` (or `set_free_mark`, called before it) writes, and that no request changed. Neighbors are joined. 12d sums these after init.

| Range | Size B | What |
|---|---|---|
| 0x002000 to 0x003000 | 4,096 | stack canary (4 KB, written by init) |
| 0x100000 to 0x1001e4 | 484 | rodata (host), rodata (roc), free mark (set once) |
| 0x1035f0 to 0x103628 | 56 | rodata (host), roc host table |
| 0x103638 to 0x103644 | 12 | canary globals (init only) |
| 0x214d9c to 0x214d9d | 1 | roc host table |
| Total, static | 4,649 | |
| Constant foreign units (unchanged after first seen) | 0 | 0 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| task records | yes: 454 of 13,324 B, 0x1001e8 to 0x101216 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| allocator globals, counters | yes: 1 of 8 B, 0x103649 to 0x10364a | 8. Host globals | range check (12d) |
| pool bounds, unit tables (U_*), page reserve table, free-run index | yes: 683 of 561,708 B, 0x10364c to 0x17cd3b | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), task records, free-run index | yes: 250 of 295,144 B, 0x18ccbc to 0x1d48a4 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| allocator globals, counters, host globals | yes: 10 of 32 B, 0x1d496c to 0x1d4985 | 8. Host globals | range check (12d) |
| WAITS (pointers to Wait records) | yes: 214 of 1,024 B, 0x214996 to 0x214adb | 8. Host globals | range check (12d) |
| host globals | yes: 1 of 4 B, 0x214d98 to 0x214d99 | 8. Host globals | range check (12d) |

### Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | none |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: every region is in a row of the PLAN 12 table.

## Output: `app_boxy` (`out/app_boxy.wasm --light`)

The boxy runtime adds foreign units, a data blob, and mutable runtime statics.

| Item | Value |
|---|---|
| File | out/app_boxy.wasm, 470,761 B, sha256 243ad690ddf4762e |
| Request mix | app: one request, seq 1, seq 2, seq 3, seq 4, many, all waiting, many, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed, unclean trap 1, unclean trap 2, unclean trap 3 |
| Map check | ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses) |
| Symbols | out/app_boxy.map (224 data symbols); name section: 0 function names, 0 data names |
| Memory at start | 46 pages (3,014,656 B), maximum none; at the end 8,519,680 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 35, cancelled (status 5): 3, trap, clean: 7, trap, NOT clean: 3 |
| After the unclean traps | live bytes 29712, canary ok 1 (the pages of an unclean task stay: the instance is replaced in production) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 400 |

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack, guard below the canary | 0x000000 | 0x002000 | 8,192 | no | 0 | 4. Shared stack |
| stack canary (4 KB, written by init) | 0x002000 | 0x003000 | 4,096 | no | 4096 | 7. Constant data (host constant) |
| shared stack | 0x003000 | 0x100000 | 1,036,288 | yes: 38,904 of 1,036,288 B, 0x0e6500 to 0x0ffffc; first in "one request" | 6 | 4. Shared stack |
| rodata (host), rodata (roc) | 0x100000 | 0x101540 | 5,440 | no | 0 | 7. Constant data |
| free mark (set once) | 0x101540 | 0x101544 | 4 | no | 4 | 8. Host globals |
| task records | 0x101544 | 0x104950 | 13,324 | yes: 282 of 13,324 B, 0x101548 to 0x104934; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| rodata (host), roc host table | 0x104950 | 0x104984 | 52 | no | 0 | 7. Constant data |
| Roc side statics (.data) | 0x104984 | 0x104a30 | 172 | yes: 10 of 172 B, 0x104a10 to 0x104a25; first in "one request" | 0 | NONE |
| roc runtime sidecar (constant data of the boxy runtime) | 0x104a30 | 0x1ce5e8 | 826,296 | no | 0 | 7. Constant data |
| allocator globals, counters, log | 0x1ce5e8 | 0x1ce5f8 | 16 | no | 0 | 8. Host globals |
| canary globals (init only) | 0x1ce5f8 | 0x1ce604 | 12 | no | 3 | 8. Host globals |
| allocator globals, counters | 0x1ce604 | 0x1ce60c | 8 | yes: 3 of 8 B, 0x1ce608 to 0x1ce60b; first in "many, all waiting" | 0 | 8. Host globals |
| pool bounds, unit tables (U_*), page reserve table, free-run index | 0x1ce60c | 0x257838 | 561,708 | yes: 3,255 of 561,708 B, 0x1ce60c to 0x2486fc; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x257838 | 0x25783c | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), task records, free-run index | 0x25783c | 0x29f924 | 295,144 | yes: 290 of 295,144 B, 0x257dfc to 0x29f89c; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| trap flag | 0x29f924 | 0x29f928 | 4 | no | 0 | 8. Host globals |
| allocator globals, counters, host globals | 0x29f928 | 0x29f948 | 32 | yes: 15 of 32 B, 0x29f92c to 0x29f945; first in "one request" | 1 | 8. Host globals |
| bench only: heap_fill | 0x29f948 | 0x2df950 | 262,152 | yes: 2,753 of 262,152 B, 0x29f948 to 0x2a08ef; first in "bench: heap_fill" | 0 | none (bench only) |
| WAITS (pointers to Wait records) | 0x2df950 | 0x2dfd50 | 1,024 | yes: 115 of 1,024 B, 0x2df979 to 0x2dfa57; first in "many, all waiting" | 0 | 8. Host globals |
| host globals | 0x2dfd50 | 0x2dfd54 | 4 | no | 0 | 8. Host globals |
| bench only: fault_next_wait | 0x2dfd54 | 0x2dfd58 | 4 | no | 0 | none (bench only) |
| host globals | 0x2dfd58 | 0x2dfd5c | 4 | yes: 1 of 4 B, 0x2dfd58 to 0x2dfd59; first in "one request" | 0 | 8. Host globals |
| roc host table | 0x2dfd5c | 0x2dfd60 | 4 | no | 0 | 7. Constant data |
| Roc side statics (.bss) | 0x2dfd60 | 0x2dfe14 | 180 | yes: 56 of 180 B, 0x2dfd62 to 0x2dfddb; first in "one request" | 0 | NONE |
| unused tail of the initial memory | 0x2dfe14 | 0x2e0000 | 492 | no | 0 | 5 (nobody writes it) |

## Heap (units of 4 KB, read from the unit tables)

Pool at the end: 0x2e0000 to 0x820000 (5,505,024 B). Counts are from the snapshot with 16 tasks waiting; "At idle" is the last snapshot with no task.

| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |
|---|---|---|---|---|---|---|
| free units | 0x780000 | 0x782000 | 2 | 8,192 | 389 | 5. Free units, page reserve |
| page reserve (empty small pages) | 0x5af000 | 0x762000 | 9 | 36,864 | 59 | 5. Free units, page reserve |
| task small pages (16 task slots) | 0x2e0000 | 0x72c000 | 33 | 135,168 | 0 | 1. Task pages and large blocks |
| task large blocks (925,120 B of it are 16 saved stack copies (row 2), found by the Wait records) | 0x492000 | 0x7a0000 | 274 | 1,122,304 | 0 | 1. Task pages and large blocks |
| host pages (slot 0) (Wait records (16 x 32 B), log lines; the response block is here for a short time) | 0x2e8000 | 0x2e9000 | 1 | 4,096 | 0 | 3. Wait record |
| JS pages (slot JS) (request blocks and response blocks of js_alloc) | 0x2e6000 | 0x2e7000 | 1 | 4,096 | 0 | 10. JS blocks |
| foreign units (roc runtime) | 0x2f0000 | 0x690000 | 896 | 3,670,016 | 896 | 9. Pages of the roc runtime (foreign units) |
| unit of kind none, not free, not reserve | - | - | 0 | 0 | 0 | none (empty) |

After init the pool has 0 units: every unit of the heap is written after init (nothing of the heap is constant from init). Wait record layout (low, top, copy ptr, copy len, out, owner, at): checked for all records (top - low = copy length, index = slot).

Host pages (slot 0) when the response block of the first request exists (between `handle` and `res_free`): 1 units, with 0 JS units. After that request: 0 host units.

| Foreign units | Value |
|---|---|
| After init | 0 |
| At the peak, at idle | 896, 896 |
| First seen in the snapshot | response block |
| Units by snapshot | init: 0; one request: 416; seq 1: 416; seq 2: 416; seq 3: 416; seq 4: 416; many, all waiting: 896; many: 896; faults, all waiting: 896; faults: 896; idle: 896; after bench: 896; unclean trap 1: 896; unclean trap 2: 896; unclean trap 3: 896 |
| Changed after the first snapshot that has them | 91 of 896 units, first changed in "seq 1" |
| Runs of foreign units (47) | constant 0x2f0000 to 0x320000; changed 0x320000 to 0x321000; constant 0x321000 to 0x330000; changed 0x330000 to 0x331000; constant 0x331000 to 0x340000; changed 0x340000 to 0x342000; constant 0x342000 to 0x350000; changed 0x350000 to 0x351000; constant 0x351000 to 0x360000; changed 0x360000 to 0x361000; constant 0x361000 to 0x370000; changed 0x370000 to 0x371000; ... |

## Constant after init

Ranges that only `init` (or `set_free_mark`, called before it) writes, and that no request changed. Neighbors are joined. 12d sums these after init.

| Range | Size B | What |
|---|---|---|
| 0x002000 to 0x003000 | 4,096 | stack canary (4 KB, written by init) |
| 0x100000 to 0x101544 | 5,444 | rodata (host), rodata (roc), free mark (set once) |
| 0x104950 to 0x104984 | 52 | rodata (host), roc host table |
| 0x104a30 to 0x1ce5e8 | 826,296 | roc runtime sidecar (constant data of the boxy runtime) |
| 0x1ce5f8 to 0x1ce604 | 12 | canary globals (init only) |
| 0x2dfd5c to 0x2dfd60 | 4 | roc host table |
| Total, static | 835,904 | |
| Constant foreign units (unchanged after first seen) | 3,297,280 | 805 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| task records | yes: 282 of 13,324 B, 0x101548 to 0x104934 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| Roc side statics (.data) | yes: 10 of 172 B, 0x104a10 to 0x104a25 | NONE | NONE |
| allocator globals, counters | yes: 3 of 8 B, 0x1ce608 to 0x1ce60b | 8. Host globals | range check (12d) |
| pool bounds, unit tables (U_*), page reserve table, free-run index | yes: 3,255 of 561,708 B, 0x1ce60c to 0x2486fc | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), task records, free-run index | yes: 290 of 295,144 B, 0x257dfc to 0x29f89c | 6. Allocator tables, task records, reserve table | structural check (12d) |
| allocator globals, counters, host globals | yes: 15 of 32 B, 0x29f92c to 0x29f945 | 8. Host globals | range check (12d) |
| WAITS (pointers to Wait records) | yes: 115 of 1,024 B, 0x2df979 to 0x2dfa57 | 8. Host globals | range check (12d) |
| host globals | yes: 1 of 4 B, 0x2dfd58 to 0x2dfd59 | 8. Host globals | range check (12d) |
| Roc side statics (.bss) | yes: 56 of 180 B, 0x2dfd62 to 0x2dfddb | NONE | NONE |

### Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 3,014,656 of 3,014,656 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | Roc side statics (.data); Roc side statics (.bss) |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: 2 region(s) are not in the table.

## Run without a map (`wasm/`, the copies from the start)

The copies are an older build of the host. Without a map the script cuts the memory into stack, data segments and bss only. Same request mix, no heap table. See `results/copy_app_nomap.md`. Exit 1 by design (the bss has no row without symbols).
