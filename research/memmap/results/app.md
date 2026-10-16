# Memory map: out/app.wasm

| Item | Value |
|---|---|
| File | out/app.wasm, 74,849 B, sha256 79041368cbc5ed36 |
| Request mix | app: one request, seq 1, seq 2, seq 3, seq 4, many, all waiting, many, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed, unclean trap 1, unclean trap 2, unclean trap 3 |
| Map check | ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses) |
| Symbols | out/app.map (109 data symbols); name section: 0 function names, 0 data names |
| Memory at start | 34 pages (2,228,224 B), maximum none; at the end 14,876,672 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 83, cancelled (status 5): 3, trap, clean: 8, trap, NOT clean: 2 |
| After the unclean traps | live bytes 0, canary ok 1 (12c: task_abort frees the pages and the slot of an unclean task, and the instance stays while the global check passes) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 400 |

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack, guard below the canary | 0x000000 | 0x002000 | 8,192 | no | 0 | 4. Shared stack |
| stack canary (4 KB, written by init) | 0x002000 | 0x003000 | 4,096 | no | 4096 | 7. Constant data (host constant) |
| shared stack | 0x003000 | 0x100000 | 1,036,288 | yes: 40,041 of 1,036,288 B, 0x0d6ed4 to 0x0ffffd; first in "one request" | 21 | 4. Shared stack |
| rodata (host), rodata (roc) | 0x100000 | 0x1003f0 | 1,008 | no | 0 | 7. Constant data |
| CPU flags of workerd, trap cause (5a, 5b) | 0x1003f0 | 0x1003f8 | 8 | no | 0 | 8. Host globals |
| task records | 0x1003f8 | 0x1007f8 | 1,024 | yes: 64 of 1,024 B, 0x1003fc to 0x1004f9; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| grow step (set once, before init), free mark (set once) | 0x1007f8 | 0x100800 | 8 | no | 4 | 8. Host globals |
| task records | 0x100800 | 0x103800 | 12,288 | yes: 652 of 12,288 B, 0x100808 to 0x1037e4; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| rodata (host) | 0x103800 | 0x103818 | 24 | no | 0 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x103818 | 0x10381c | 4 | no | 0 | 8. Host globals |
| roc host table | 0x10381c | 0x103838 | 28 | no | 0 | 7. Constant data |
| bench only: set_wild, poke_wait | 0x103838 | 0x103840 | 8 | no | 0 | none (bench only) |
| CPU flags of workerd, trap cause (5a, 5b) | 0x103840 | 0x103844 | 4 | yes: 1 of 4 B, 0x103840 to 0x103841; first in "faults" | 0 | 8. Host globals |
| allocator globals, counters, log | 0x103844 | 0x103854 | 16 | no | 0 | 8. Host globals |
| canary globals (init only) | 0x103854 | 0x103860 | 12 | no | 3 | 8. Host globals |
| allocator globals, counters, allocator counters of H3 and the idle reset (4h, 4j) | 0x103860 | 0x10386c | 12 | yes: 6 of 12 B, 0x103864 to 0x10386b; first in "one request" | 0 | 8. Host globals |
| pool bounds, unit tables (U_*) | 0x10386c | 0x113874 | 65,544 | yes: 3,439 of 65,544 B, 0x10386c to 0x10c69f; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x113874 | 0x113878 | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), page reserve table | 0x113878 | 0x16b87c | 360,452 | yes: 2,991 of 360,452 B, 0x113a98 to 0x16b87a; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator counters of H3 and the idle reset (4h, 4j) | 0x16b87c | 0x16b884 | 8 | no | 0 | 8. Host globals |
| page reserve table, pool bounds, free-run index, unit tables (U_*) | 0x16b884 | 0x18caa0 | 135,708 | yes: 2,007 of 135,708 B, 0x16b884 to 0x17e442; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x18caa0 | 0x18caa4 | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), task records, free-run index | 0x18caa4 | 0x1d4b8c | 295,144 | yes: 1,059 of 295,144 B, 0x18cee4 to 0x1d4b12; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| trap flag | 0x1d4b8c | 0x1d4b90 | 4 | no | 0 | 8. Host globals |
| export counter RUN_EPOCH (12b) | 0x1d4b90 | 0x1d4b94 | 4 | yes: 2 of 4 B, 0x1d4b90 to 0x1d4b92; first in "one request" | 1 | 8. Host globals |
| allocator counters of H3 and the idle reset (4h, 4j) | 0x1d4b94 | 0x1d4ba0 | 12 | no | 0 | 8. Host globals |
| allocator globals, counters, host globals | 0x1d4ba0 | 0x1d4bc0 | 32 | yes: 15 of 32 B, 0x1d4ba0 to 0x1d4bbf; first in "one request" | 1 | 8. Host globals |
| bench only: heap_fill | 0x1d4bc0 | 0x214bc8 | 262,152 | yes: 2,753 of 262,152 B, 0x1d4bc0 to 0x1d5b67; first in "bench: heap_fill" | 0 | none (bench only) |
| WAITS (pointers to Wait records) | 0x214bc8 | 0x214fc8 | 1,024 | yes: 258 of 1,024 B, 0x214bf1 to 0x214e4f; first in "many, all waiting" | 0 | 8. Host globals |
| sum of the constant data (12d, set by init) | 0x214fc8 | 0x214fd0 | 8 | no | 8 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x214fd0 | 0x214fd4 | 4 | no | 0 | 8. Host globals |
| bench only: fault_next_wait | 0x214fd4 | 0x214fd8 | 4 | no | 0 | none (bench only) |
| host globals | 0x214fd8 | 0x214fdc | 4 | yes: 1 of 4 B, 0x214fd8 to 0x214fd9; first in "one request" | 0 | 8. Host globals |
| allocator globals, counters | 0x214fdc | 0x214fe0 | 4 | no | 1 | 8. Host globals |
| scratch bitmap of check_heap (cleared at each check) | 0x214fe0 | 0x215fe0 | 4,096 | yes: 386 of 4,096 B, 0x215024 to 0x2151a6; first in "seq 1" | 0 | 6. Allocator tables, task records, reserve table |
| roc host table | 0x215fe0 | 0x215fe4 | 4 | no | 0 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x215fe4 | 0x215fe8 | 4 | yes: 1 of 4 B, 0x215fe4 to 0x215fe5; first in "unclean trap 1" | 0 | 8. Host globals |
| bench only: leak_next, bench only: set_wild, poke_wait | 0x215fe8 | 0x215ff4 | 12 | no | 0 | none (bench only) |
| sum mode, alarm counters (12a, 12b) | 0x215ff4 | 0x215ff8 | 4 | yes: 1 of 4 B, 0x215ff4 to 0x215ff5; first in "one request" | 0 | 8. Host globals |
| bench only: set_wild, poke_wait | 0x215ff8 | 0x216000 | 8 | no | 0 | none (bench only) |
| Roc code statics (roc_tail_*) | 0x216000 | 0x2160e0 | 224 | yes: 52 of 224 B, 0x216010 to 0x2160cc; first in "one request" | 0 | 12. Roc code statics |
| unused tail of the initial memory | 0x2160e0 | 0x220000 | 40,736 | no | 0 | 5 (nobody writes it) |

## Heap (units of 4 KB, read from the unit tables)

Pool at the end: 0x220000 to 0xe30000 (12,648,448 B). Counts are from the snapshot with 64 tasks waiting; "At idle" is the last snapshot with no task.

| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |
|---|---|---|---|---|---|---|
| free units | 0xced000 | 0xe2a000 | 19 | 77,824 | 2832 | 5. Free units, page reserve |
| page reserve (empty small pages) | 0x220000 | 0xcd1000 | 123 | 503,808 | 256 | 5. Free units, page reserve |
| task small pages (64 task slots) | 0x222000 | 0xccf000 | 144 | 589,824 | 0 | 1. Task pages and large blocks |
| task large blocks (2,029,312 B of it are 64 saved stack copies (row 2), found by the Wait records) | 0x23c000 | 0xe30000 | 2,800 | 11,468,800 | 0 | 1. Task pages and large blocks |
| host pages (slot 0) (Wait records (64 x 48 B), log lines; the response block is here for a short time) | 0x2ca000 | 0x2cb000 | 1 | 4,096 | 0 | 3. Wait record |
| JS pages (slot JS) (request blocks and response blocks of js_alloc) | 0x223000 | 0x224000 | 1 | 4,096 | 0 | 10. JS blocks |
| foreign units (roc runtime) | - | - | 0 | 0 | 0 | 9. Pages of the roc runtime (foreign units) |
| unit of kind none, not free, not reserve | - | - | 0 | 0 | 0 | none (empty) |
| response block of a task that ended (first request, from the return of handle to res_free) (in a host page) | 0x234000 | 0x234030 | 1 | 48 | - | 11. Response block of a task that ended |

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
| 0x100000 to 0x1003f0 | 1,008 | rodata (host), rodata (roc) |
| 0x1007f8 to 0x100800 | 8 | grow step (set once, before init), free mark (set once) |
| 0x103800 to 0x103818 | 24 | rodata (host) |
| 0x10381c to 0x103838 | 28 | roc host table |
| 0x103854 to 0x103860 | 12 | canary globals (init only) |
| 0x214fc8 to 0x214fd0 | 8 | sum of the constant data (12d, set by init) |
| 0x215fe0 to 0x215fe4 | 4 | roc host table |
| Total, static | 5,188 | |
| Constant foreign units (unchanged after first seen) | 0 | 0 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| task records | yes: 64 of 1,024 B, 0x1003fc to 0x1004f9 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| task records | yes: 652 of 12,288 B, 0x100808 to 0x1037e4 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| CPU flags of workerd, trap cause (5a, 5b) | yes: 1 of 4 B, 0x103840 to 0x103841 | 8. Host globals | range check (12d) |
| allocator globals, counters, allocator counters of H3 and the idle reset (4h, 4j) | yes: 6 of 12 B, 0x103864 to 0x10386b | 8. Host globals | range check (12d) |
| pool bounds, unit tables (U_*) | yes: 3,439 of 65,544 B, 0x10386c to 0x10c69f | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), page reserve table | yes: 2,991 of 360,452 B, 0x113a98 to 0x16b87a | 6. Allocator tables, task records, reserve table | structural check (12d) |
| page reserve table, pool bounds, free-run index, unit tables (U_*) | yes: 2,007 of 135,708 B, 0x16b884 to 0x17e442 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), task records, free-run index | yes: 1,059 of 295,144 B, 0x18cee4 to 0x1d4b12 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| export counter RUN_EPOCH (12b) | yes: 2 of 4 B, 0x1d4b90 to 0x1d4b92 | 8. Host globals | range check (12d) |
| allocator globals, counters, host globals | yes: 15 of 32 B, 0x1d4ba0 to 0x1d4bbf | 8. Host globals | range check (12d) |
| WAITS (pointers to Wait records) | yes: 258 of 1,024 B, 0x214bf1 to 0x214e4f | 8. Host globals | range check (12d) |
| host globals | yes: 1 of 4 B, 0x214fd8 to 0x214fd9 | 8. Host globals | range check (12d) |
| scratch bitmap of check_heap (cleared at each check) | yes: 386 of 4,096 B, 0x215024 to 0x2151a6 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| sum mode, alarm counters (12a, 12b) | yes: 1 of 4 B, 0x215fe4 to 0x215fe5 | 8. Host globals | range check (12d) |
| sum mode, alarm counters (12a, 12b) | yes: 1 of 4 B, 0x215ff4 to 0x215ff5 | 8. Host globals | range check (12d) |
| Roc code statics (roc_tail_*) | yes: 52 of 224 B, 0x216010 to 0x2160cc | 12. Roc code statics | none (never live across a wait) |

## Detail: each symbol of the data and bss

| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |
|---|---|---|---|---|---|---|
| __anon_1664 | 0x100000 | 128 | .rodata | host | no | 7. Constant data |
| __anon_1178 | 0x100080 | 52 | .rodata | host | no | 7. Constant data |
| __anon_1812 | 0x1000b8 | 104 | .rodata | host | no | 7. Constant data |
| .roc.bytes.0 | 0x100120 | 19 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.1 | 0x100140 | 33 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.2 | 0x100170 | 27 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.4 | 0x100190 | 21 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.5 | 0x1001b0 | 64 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.6 | 0x1001f0 | 30 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.7 | 0x100210 | 17 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.8 | 0x100230 | 25 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.9 | 0x100249 | 12 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.10 | 0x100260 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_7829 | 0x10027b | 74 | .rodata | roc | no | 7. Constant data |
| __anon_8699 | 0x1002c5 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_10450 | 0x1002c8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_10522 | 0x1002d4 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10523 | 0x1002d8 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10524 | 0x1002dc | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10525 | 0x1002e0 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10527 | 0x1002e4 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10675 | 0x1002e8 | 256 | .rodata | roc | no | 7. Constant data |
| cpu.__instance_terminated | 0x1003f0 | 4 | .data | host | no | 8. Host globals |
| cpu.__instance_signal | 0x1003f4 | 4 | .data | host | no | 8. Host globals |
| alloc.SLOT_OWNER | 0x1003f8 | 1,024 | .data | host | yes: 64 of 1,024 B, 0x1003fc to 0x1004f9 | 6. Allocator tables, task records, reserve table |
| alloc.GROW_CHUNKS | 0x1007f8 | 4 | .data | host | no | 8. Host globals |
| alloc.FREE_MARK | 0x1007fc | 4 | .data | host | no | 8. Host globals |
| alloc.TASKS | 0x100800 | 12,288 | .data | host | yes: 652 of 12,288 B, 0x100808 to 0x1037e4 | 6. Allocator tables, task records, reserve table |
| __anon_2672 | 0x103800 | 8 | .data.rel.ro | host | no | 7. Constant data |
| alloc.vtable | 0x103808 | 16 | .data.rel.ro | host | no | 7. Constant data |
| host.SUM_MODE | 0x103818 | 4 | .data | host | no | 8. Host globals |
| roc.RocHostOf(roc_platform_abi.RocHost).host | 0x10381c | 28 | .data | host | no | 7. Constant data |
| host.WILD_WORDS | 0x103838 | 4 | .data | host | no | none (bench only) |
| host.WILD_SEED | 0x10383c | 4 | .data | host | no | none (bench only) |
| cpu.CAUSE | 0x103840 | 4 | .bss | host | yes: 1 of 4 B, 0x103840 to 0x103841 | 8. Host globals |
| alloc.OWNER | 0x103844 | 4 | .bss | host | no | 8. Host globals |
| roc.LOG | 0x103848 | 12 | .bss | host | no | 8. Host globals |
| canary.STACK_LIMIT | 0x103854 | 4 | .bss | host | no | 8. Host globals |
| canary.CANARY_BASE | 0x103858 | 4 | .bss | host | no | 8. Host globals |
| canary.STACK_FIRST | 0x10385c | 1 | .bss | host | no | 8. Host globals |
| alloc.FAIL_AT | 0x103860 | 4 | .bss | host | no | 8. Host globals |
| alloc.LIVE_BYTES | 0x103864 | 4 | .bss | host | yes: 3 of 4 B, 0x103864 to 0x103867 | 8. Host globals |
| alloc.LIVE_PEAK | 0x103868 | 4 | .bss | host | yes: 3 of 4 B, 0x103868 to 0x10386b | 8. Host globals |
| alloc.POOL_LO | 0x10386c | 4 | .bss | host | yes: 2 of 4 B, 0x10386c to 0x10386e | 6. Allocator tables, task records, reserve table |
| alloc.POOL_HI | 0x103870 | 4 | .bss | host | yes: 2 of 4 B, 0x103870 to 0x103872 | 6. Allocator tables, task records, reserve table |
| alloc.U_KIND | 0x103874 | 32,768 | .bss | host | yes: 2,947 of 32,768 B, 0x103a96 to 0x1046a4 | 6. Allocator tables, task records, reserve table |
| alloc.U_SLOT | 0x10b874 | 32,768 | .bss | host | yes: 488 of 32,768 B, 0x10ba94 to 0x10c69f | 6. Allocator tables, task records, reserve table |
| alloc.DEALLOC_MISS | 0x113874 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_CLASS | 0x113878 | 32,768 | .bss | host | yes: 269 of 32,768 B, 0x113a98 to 0x114549 | 6. Allocator tables, task records, reserve table |
| alloc.U_UNITS | 0x11b878 | 65,536 | .bss | host | yes: 812 of 65,536 B, 0x11bcb8 to 0x11d4cd | 6. Allocator tables, task records, reserve table |
| alloc.U_HW | 0x12b878 | 131,072 | .bss | host | yes: 326 of 131,072 B, 0x12c168 to 0x12f122 | 6. Allocator tables, task records, reserve table |
| alloc.U_NEXT | 0x14b878 | 65,536 | .bss | host | yes: 808 of 65,536 B, 0x14bcb8 to 0x14d4ce | 6. Allocator tables, task records, reserve table |
| alloc.U_PREV | 0x15b878 | 65,536 | .bss | host | yes: 774 of 65,536 B, 0x15bcb8 to 0x15d49a | 6. Allocator tables, task records, reserve table |
| alloc.CACHED | 0x16b878 | 4 | .bss | host | yes: 2 of 4 B, 0x16b878 to 0x16b87a | 6. Allocator tables, task records, reserve table |
| alloc.RECLAIMS | 0x16b87c | 4 | .bss | host | no | 8. Host globals |
| alloc.RECLAIMED | 0x16b880 | 4 | .bss | host | no | 8. Host globals |
| alloc.CACHE | 0x16b884 | 512 | .bss | host | yes: 512 of 512 B, 0x16b884 to 0x16ba84 | 6. Allocator tables, task records, reserve table |
| alloc.CHUNKS_USED | 0x16ba84 | 4 | .bss | host | yes: 2 of 4 B, 0x16ba84 to 0x16ba86 | 6. Allocator tables, task records, reserve table |
| alloc.FREE_BITS | 0x16ba88 | 4,096 | .bss | host | yes: 371 of 4,096 B, 0x16bacc to 0x16bc4e | 6. Allocator tables, task records, reserve table |
| alloc.U_START | 0x16ca88 | 65,536 | .bss | host | yes: 640 of 65,536 B, 0x16cece to 0x16e6e8 | 6. Allocator tables, task records, reserve table |
| alloc.GROWN_END | 0x17ca88 | 4 | .bss | host | yes: 1 of 4 B, 0x17ca8a to 0x17ca8b | 6. Allocator tables, task records, reserve table |
| alloc.RL_FLBITS | 0x17ca8c | 2 | .bss | host | yes: 1 of 2 B, 0x17ca8c to 0x17ca8d | 6. Allocator tables, task records, reserve table |
| alloc.RL_SLBITS | 0x17ca8e | 14 | .bss | host | yes: 6 of 14 B, 0x17ca8e to 0x17ca95 | 6. Allocator tables, task records, reserve table |
| alloc.LOW_HINT | 0x17ca9c | 4 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_BUMP | 0x17caa0 | 65,536 | .bss | host | yes: 474 of 65,536 B, 0x17cee0 to 0x17e442 | 6. Allocator tables, task records, reserve table |
| alloc.DOUBLE_FREES | 0x18caa0 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_FREE | 0x18caa4 | 65,536 | .bss | host | yes: 429 of 65,536 B, 0x18cee4 to 0x18e445 | 6. Allocator tables, task records, reserve table |
| alloc.U_INAV | 0x19caa4 | 32,768 | .bss | host | yes: 137 of 32,768 B, 0x19ccc6 to 0x19d773 | 6. Allocator tables, task records, reserve table |
| alloc.U_LIVE | 0x1a4aa4 | 65,536 | .bss | host | yes: 147 of 65,536 B, 0x1a4ee8 to 0x1a6441 | 6. Allocator tables, task records, reserve table |
| alloc.U_ANEXT | 0x1b4aa4 | 65,536 | .bss | host | yes: 310 of 65,536 B, 0x1b4ee4 to 0x1b6444 | 6. Allocator tables, task records, reserve table |
| alloc.U_APREV | 0x1c4aa4 | 65,536 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.LAST_OWNER | 0x1d4aa4 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4aa4 to 0x1d4aa5 | 6. Allocator tables, task records, reserve table |
| alloc.LAST_SLOT | 0x1d4aa8 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4aa8 to 0x1d4aa9 | 6. Allocator tables, task records, reserve table |
| alloc.RL_HEAD | 0x1d4aac | 224 | .bss | host | yes: 34 of 224 B, 0x1d4aae to 0x1d4b12 | 6. Allocator tables, task records, reserve table |
| mem.TRAP_CLEAN | 0x1d4b8c | 1 | .bss | host | no | 8. Host globals |
| mem.RUN_EPOCH | 0x1d4b90 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4b90 to 0x1d4b92 | 8. Host globals |
| alloc.RESET_BYTES | 0x1d4b94 | 4 | .bss | host | no | 8. Host globals |
| alloc.RESETS | 0x1d4b98 | 4 | .bss | host | no | 8. Host globals |
| alloc.LEAKED | 0x1d4b9c | 4 | .bss | host | no | 8. Host globals |
| alloc.ROC_BYTES | 0x1d4ba0 | 4 | .bss | host | yes: 4 of 4 B, 0x1d4ba0 to 0x1d4ba4 | 8. Host globals |
| host.TASK_TOP | 0x1d4ba4 | 4 | .bss | host | no | 8. Host globals |
| host.TASK_WAITING | 0x1d4ba8 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4ba8 to 0x1d4ba9 | 8. Host globals |
| host.COPY | 0x1d4bac | 1 | .bss | host | no | 8. Host globals |
| host.TASK_WAITS | 0x1d4bb0 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4bb0 to 0x1d4bb1 | 8. Host globals |
| host.TASK_SAVED_MAX | 0x1d4bb4 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4bb4 to 0x1d4bb7 | 8. Host globals |
| host.TASK_SAVED_PEAK | 0x1d4bb8 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4bb8 to 0x1d4bbb | 8. Host globals |
| host.TASK_SAVED | 0x1d4bbc | 4 | .bss | host | yes: 3 of 4 B, 0x1d4bbc to 0x1d4bbf | 8. Host globals |
| host.FILL_TAG | 0x1d4bc0 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4bc0 to 0x1d4bc1 | none (bench only) |
| host.FILLED | 0x1d4bc4 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4bc4 to 0x1d4bc6 | none (bench only) |
| host.FILL | 0x1d4bc8 | 262,144 | .bss | host | yes: 2,750 of 262,144 B, 0x1d4bc9 to 0x1d5b67 | none (bench only) |
| host.WAITS | 0x214bc8 | 1,024 | .bss | host | yes: 258 of 1,024 B, 0x214bf1 to 0x214e4f | 8. Host globals |
| host.CONST_SUM | 0x214fc8 | 8 | .bss | host | no | 7. Constant data |
| host.SUSPECT | 0x214fd0 | 1 | .bss | host | no | 8. Host globals |
| host.FAULT_NEXT | 0x214fd4 | 4 | .bss | host | no | none (bench only) |
| host.WAITS_FREE_HINT | 0x214fd8 | 4 | .bss | host | yes: 1 of 4 B, 0x214fd8 to 0x214fd9 | 8. Host globals |
| alloc.INIT_MEM_END | 0x214fdc | 4 | .bss | host | no | 8. Host globals |
| alloc.SEEN | 0x214fe0 | 4,096 | .bss | host | yes: 386 of 4,096 B, 0x215024 to 0x2151a6 | 6. Allocator tables, task records, reserve table |
| roc.RocHostOf(roc_platform_abi.RocHost).env | 0x215fe0 | 1 | .bss | host | no | 7. Constant data |
| host.ALARMS | 0x215fe4 | 4 | .bss | host | yes: 1 of 4 B, 0x215fe4 to 0x215fe5 | 8. Host globals |
| host.LEAK_NEXT | 0x215fe8 | 4 | .bss | host | no | none (bench only) |
| host.POKE_OUT | 0x215fec | 4 | .bss | host | no | none (bench only) |
| host.WILD_TRAP | 0x215ff0 | 4 | .bss | host | no | none (bench only) |
| host.SUM_CHECKS | 0x215ff4 | 4 | .bss | host | yes: 1 of 4 B, 0x215ff4 to 0x215ff5 | 8. Host globals |
| host.POKE_OUT_ADD | 0x215ff8 | 4 | .bss | host | no | none (bench only) |
| host.WILD_BASE | 0x215ffc | 4 | .bss | host | no | none (bench only) |
| roc_tail_pending | 0x216000 | 4 | .bss | roc | no | 12. Roc code statics |
| roc_tail_args | 0x216010 | 208 | .bss | roc | yes: 52 of 208 B, 0x216010 to 0x2160cc | 12. Roc code statics |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | CPU flags of workerd, trap cause (5a, 5b); sum mode, alarm counters (12a, 12b); allocator globals, counters, log; allocator globals, counters; allocator counters of H3 and the idle reset (4h, 4j); allocator globals, counters; trap flag; allocator counters of H3 and the idle reset (4h, 4j); sum mode, alarm counters (12a, 12b); allocator globals, counters |
| Regions with no PLAN 12 row | none |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| check_heap (12d) after a flip of each byte of the constant symbols and the canary | 5097 of 5097 found (codes 12: 5096, trap: 1); after the last flip back: 0 |
| check_heap (12d) after each phase | 0 (pass) in all 10 phases |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: set_wild, poke_wait, 8 B; bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B; bench only: leak_next, bench only: set_wild, poke_wait, 12 B; bench only: set_wild, poke_wait, 8 B |

RESULT: every region is in a row of the PLAN 12 table.
