# Memory map: out/app_deep.wasm

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

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack, guard below the canary | 0x000000 | 0x002000 | 8,192 | yes: 102 of 8,192 B, 0x0000e0 to 0x001fd3; first in "overflow, no alloc" | 0 | 4. Shared stack |
| stack canary (4 KB, written by init) | 0x002000 | 0x003000 | 4,096 | no | 4096 | 7. Constant data (host constant) |
| shared stack | 0x003000 | 0x100000 | 1,036,288 | yes: 213,617 of 1,036,288 B, 0x003084 to 0x0ffffd; first in "one request" | 6 | 4. Shared stack |
| rodata (host), rodata (roc) | 0x100000 | 0x1001e0 | 480 | no | 0 | 7. Constant data |
| free mark (set once) | 0x1001e0 | 0x1001e4 | 4 | no | 4 | 8. Host globals |
| task records | 0x1001e4 | 0x1035f0 | 13,324 | yes: 454 of 13,324 B, 0x1001e8 to 0x101216; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| rodata (host), roc host table | 0x1035f0 | 0x103628 | 56 | no | 0 | 7. Constant data |
| allocator globals, counters, log | 0x103628 | 0x103638 | 16 | no | 0 | 8. Host globals |
| canary globals (init only) | 0x103638 | 0x103644 | 12 | no | 3 | 8. Host globals |
| allocator globals, counters | 0x103644 | 0x10364c | 8 | yes: 1 of 8 B, 0x103649 to 0x10364a; first in "many, all waiting" | 0 | 8. Host globals |
| pool bounds, unit tables (U_*), page reserve table, free-run index | 0x10364c | 0x18c878 | 561,708 | yes: 683 of 561,708 B, 0x10364c to 0x17cd3b; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x18c878 | 0x18c87c | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), task records, free-run index | 0x18c87c | 0x1d4964 | 295,144 | yes: 250 of 295,144 B, 0x18ccbc to 0x1d48a4; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| trap flag | 0x1d4964 | 0x1d4968 | 4 | no | 0 | 8. Host globals |
| allocator globals, counters, host globals | 0x1d4968 | 0x1d4988 | 32 | yes: 10 of 32 B, 0x1d496c to 0x1d4985; first in "one request" | 1 | 8. Host globals |
| bench only: heap_fill | 0x1d4988 | 0x214990 | 262,152 | yes: 2,745 of 262,152 B, 0x1d4988 to 0x1d592f; first in "bench: heap_fill" | 0 | none (bench only) |
| WAITS (pointers to Wait records) | 0x214990 | 0x214d90 | 1,024 | yes: 214 of 1,024 B, 0x214996 to 0x214adb; first in "many, all waiting" | 0 | 8. Host globals |
| host globals | 0x214d90 | 0x214d94 | 4 | no | 0 | 8. Host globals |
| bench only: fault_next_wait | 0x214d94 | 0x214d98 | 4 | no | 0 | none (bench only) |
| host globals | 0x214d98 | 0x214d9c | 4 | yes: 1 of 4 B, 0x214d98 to 0x214d99; first in "one request" | 0 | 8. Host globals |
| roc host table | 0x214d9c | 0x214d9d | 1 | no | 0 | 7. Constant data |
| unused tail of the initial memory | 0x214d9d | 0x220000 | 45,667 | no | 0 | 5 (nobody writes it) |

## Heap (units of 4 KB, read from the unit tables)

Pool at the end: 0x220000 to 0x270000 (327,680 B). Counts are from the snapshot with 64 tasks waiting; "At idle" is the last snapshot with no task.

| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |
|---|---|---|---|---|---|---|
| free units | 0x261000 | 0x270000 | 15 | 61,440 | 14 | 5. Free units, page reserve |
| page reserve (empty small pages) | - | - | 0 | 0 | 66 | 5. Free units, page reserve |
| task small pages (64 task slots) | 0x221000 | 0x261000 | 64 | 262,144 | 0 | 1. Task pages and large blocks |
| task large blocks (39,936 B of it are 64 saved stack copies (row 2), found by the Wait records) | - | - | 0 | 0 | 0 | 1. Task pages and large blocks |
| host pages (slot 0) (Wait records (64 x 32 B), log lines; the response block is here for a short time) | 0x220000 | 0x221000 | 1 | 4,096 | 0 | 3. Wait record |
| JS pages (slot JS) (request blocks and response blocks of js_alloc) | - | - | 0 | 0 | 0 | 10. JS blocks |
| foreign units (roc runtime) | - | - | 0 | 0 | 0 | 9. Pages of the roc runtime (foreign units) |
| unit of kind none, not free, not reserve | - | - | 0 | 0 | 0 | none (empty) |

After init the pool has 0 units: every unit of the heap is written after init (nothing of the heap is constant from init). Wait record layout (low, top, copy ptr, copy len, out, owner, at): checked for all records (top - low = copy length, index = slot).

Host pages (slot 0) when the response block of the first request exists (between `handle` and `res_free`): 1 units, with 0 JS units. After that request: 0 host units.

| Foreign units | Value |
|---|---|
| After init | 0 |
| At the peak, at idle | 0, 0 |
| First seen in the snapshot | never |
| Units by snapshot | init: 0; one request: 0; many, all waiting: 0; many: 0; overflow, no alloc: 0; overflow, alloc: 0; faults, all waiting: 0; faults: 0; idle: 0; after bench: 0; unclean trap 1: 0; unclean trap 2: 0; unclean trap 3: 0 |
| Changed after the first snapshot that has them | 0 of 0 units |

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

## Detail: each symbol of the data and bss

| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |
|---|---|---|---|---|---|---|
| __anon_1652 | 0x100000 | 128 | .rodata | host | no | 7. Constant data |
| __anon_1166 | 0x100080 | 52 | .rodata | host | no | 7. Constant data |
| __anon_1767 | 0x1000b8 | 104 | .rodata | host | no | 7. Constant data |
| __anon_1994 | 0x100120 | 8 | .rodata | host | no | 7. Constant data |
| .roc.bytes.1 | 0x100130 | 33 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.2 | 0x100160 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_7829 | 0x10017b | 74 | .rodata | roc | no | 7. Constant data |
| __anon_8699 | 0x1001c5 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_10450 | 0x1001c8 | 12 | .rodata | roc | no | 7. Constant data |
| alloc.FREE_MARK | 0x1001e0 | 4 | .data | host | no | 8. Host globals |
| alloc.SLOT_OWNER | 0x1001e4 | 1,024 | .data | host | yes: 64 of 1,024 B, 0x1001e8 to 0x1002e5 | 6. Allocator tables, task records, reserve table |
| alloc.TASKS | 0x1005f0 | 12,288 | .data | host | yes: 390 of 12,288 B, 0x1005f8 to 0x101216 | 6. Allocator tables, task records, reserve table |
| __anon_2300 | 0x1035f0 | 8 | .data.rel.ro | host | no | 7. Constant data |
| alloc.vtable | 0x1035f8 | 16 | .data.rel.ro | host | no | 7. Constant data |
| roc.RocHostOf(roc_platform_abi.RocHost).host | 0x103608 | 28 | .data | host | no | 7. Constant data |
| alloc.OWNER | 0x103628 | 4 | .bss | host | no | 8. Host globals |
| roc.LOG | 0x10362c | 12 | .bss | host | no | 8. Host globals |
| canary.STACK_LIMIT | 0x103638 | 4 | .bss | host | no | 8. Host globals |
| canary.CANARY_BASE | 0x10363c | 4 | .bss | host | no | 8. Host globals |
| canary.STACK_FIRST | 0x103640 | 1 | .bss | host | no | 8. Host globals |
| alloc.FAIL_AT | 0x103644 | 4 | .bss | host | no | 8. Host globals |
| alloc.LIVE_BYTES | 0x103648 | 4 | .bss | host | yes: 1 of 4 B, 0x103649 to 0x10364a | 8. Host globals |
| alloc.POOL_LO | 0x10364c | 4 | .bss | host | yes: 2 of 4 B, 0x10364c to 0x10364e | 6. Allocator tables, task records, reserve table |
| alloc.POOL_HI | 0x103650 | 4 | .bss | host | yes: 2 of 4 B, 0x103650 to 0x103652 | 6. Allocator tables, task records, reserve table |
| alloc.U_KIND | 0x103654 | 32,768 | .bss | host | yes: 65 of 32,768 B, 0x103874 to 0x1038b5 | 6. Allocator tables, task records, reserve table |
| alloc.U_CLASS | 0x10b654 | 32,768 | .bss | host | yes: 66 of 32,768 B, 0x10b874 to 0x10b8b6 | 6. Allocator tables, task records, reserve table |
| alloc.U_UNITS | 0x113654 | 65,536 | .bss | host | yes: 67 of 65,536 B, 0x113a94 to 0x113b19 | 6. Allocator tables, task records, reserve table |
| alloc.U_HW | 0x123654 | 131,072 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_SLOT | 0x143654 | 32,768 | .bss | host | yes: 66 of 32,768 B, 0x143874 to 0x1438b6 | 6. Allocator tables, task records, reserve table |
| alloc.U_NEXT | 0x14b654 | 65,536 | .bss | host | yes: 30 of 65,536 B, 0x14baf4 to 0x14bb16 | 6. Allocator tables, task records, reserve table |
| alloc.U_PREV | 0x15b654 | 65,536 | .bss | host | yes: 112 of 65,536 B, 0x15ba96 to 0x15bb18 | 6. Allocator tables, task records, reserve table |
| alloc.CACHED | 0x16b654 | 4 | .bss | host | yes: 1 of 4 B, 0x16b654 to 0x16b655 | 6. Allocator tables, task records, reserve table |
| alloc.CACHE | 0x16b658 | 512 | .bss | host | yes: 132 of 512 B, 0x16b658 to 0x16b6dc | 6. Allocator tables, task records, reserve table |
| alloc.CHUNKS_USED | 0x16b858 | 4 | .bss | host | yes: 1 of 4 B, 0x16b858 to 0x16b859 | 6. Allocator tables, task records, reserve table |
| alloc.FREE_BITS | 0x16b860 | 4,096 | .bss | host | yes: 4 of 4,096 B, 0x16b8a4 to 0x16b8ae | 6. Allocator tables, task records, reserve table |
| alloc.U_START | 0x16c860 | 65,536 | .bss | host | yes: 10 of 65,536 B, 0x16ccbe to 0x16cd40 | 6. Allocator tables, task records, reserve table |
| alloc.GROWN_END | 0x17c860 | 4 | .bss | host | yes: 1 of 4 B, 0x17c862 to 0x17c863 | 6. Allocator tables, task records, reserve table |
| alloc.RL_FLBITS | 0x17c864 | 2 | .bss | host | yes: 1 of 2 B, 0x17c864 to 0x17c865 | 6. Allocator tables, task records, reserve table |
| alloc.RL_SLBITS | 0x17c866 | 14 | .bss | host | yes: 1 of 14 B, 0x17c867 to 0x17c868 | 6. Allocator tables, task records, reserve table |
| alloc.LOW_HINT | 0x17c874 | 4 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_BUMP | 0x17c878 | 65,536 | .bss | host | yes: 122 of 65,536 B, 0x17ccb8 to 0x17cd3b | 6. Allocator tables, task records, reserve table |
| alloc.DOUBLE_FREES | 0x18c878 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_FREE | 0x18c87c | 65,536 | .bss | host | yes: 82 of 65,536 B, 0x18ccbc to 0x18cd3f | 6. Allocator tables, task records, reserve table |
| alloc.U_INAV | 0x19c87c | 32,768 | .bss | host | yes: 65 of 32,768 B, 0x19ca9c to 0x19cadd | 6. Allocator tables, task records, reserve table |
| alloc.U_LIVE | 0x1a487c | 65,536 | .bss | host | yes: 65 of 65,536 B, 0x1a4cbc to 0x1a4d3d | 6. Allocator tables, task records, reserve table |
| alloc.U_ANEXT | 0x1b487c | 65,536 | .bss | host | yes: 30 of 65,536 B, 0x1b4d1c to 0x1b4d3e | 6. Allocator tables, task records, reserve table |
| alloc.U_APREV | 0x1c487c | 65,536 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.LAST_OWNER | 0x1d487c | 4 | .bss | host | yes: 1 of 4 B, 0x1d487c to 0x1d487d | 6. Allocator tables, task records, reserve table |
| alloc.LAST_SLOT | 0x1d4880 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4880 to 0x1d4881 | 6. Allocator tables, task records, reserve table |
| alloc.RL_HEAD | 0x1d4884 | 224 | .bss | host | yes: 6 of 224 B, 0x1d489e to 0x1d48a4 | 6. Allocator tables, task records, reserve table |
| mem.TRAP_CLEAN | 0x1d4964 | 1 | .bss | host | no | 8. Host globals |
| alloc.DEALLOC_MISS | 0x1d4968 | 4 | .bss | host | no | 8. Host globals |
| alloc.ROC_BYTES | 0x1d496c | 4 | .bss | host | yes: 3 of 4 B, 0x1d496c to 0x1d496f | 8. Host globals |
| host.COPY | 0x1d4970 | 1 | .bss | host | no | 8. Host globals |
| host.TASK_WAITS | 0x1d4974 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4974 to 0x1d4975 | 8. Host globals |
| host.TASK_SAVED_MAX | 0x1d4978 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4978 to 0x1d497a | 8. Host globals |
| host.TASK_SAVED_PEAK | 0x1d497c | 4 | .bss | host | yes: 2 of 4 B, 0x1d497c to 0x1d497e | 8. Host globals |
| host.TASK_SAVED | 0x1d4980 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4981 to 0x1d4982 | 8. Host globals |
| host.TASK_WAITING | 0x1d4984 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4984 to 0x1d4985 | 8. Host globals |
| host.FILL_TAG | 0x1d4988 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4988 to 0x1d4989 | none (bench only) |
| host.FILLED | 0x1d498c | 4 | .bss | host | yes: 2 of 4 B, 0x1d498c to 0x1d498e | none (bench only) |
| host.FILL | 0x1d4990 | 262,144 | .bss | host | yes: 2,742 of 262,144 B, 0x1d4991 to 0x1d592f | none (bench only) |
| host.WAITS | 0x214990 | 1,024 | .bss | host | yes: 214 of 1,024 B, 0x214996 to 0x214adb | 8. Host globals |
| host.TASK_TOP | 0x214d90 | 4 | .bss | host | no | 8. Host globals |
| host.FAULT_NEXT | 0x214d94 | 4 | .bss | host | no | none (bench only) |
| host.WAITS_FREE_HINT | 0x214d98 | 4 | .bss | host | yes: 1 of 4 B, 0x214d98 to 0x214d99 | 8. Host globals |
| roc.RocHostOf(roc_platform_abi.RocHost).env | 0x214d9c | 1 | .bss | host | no | 7. Constant data |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | none |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: every region is in a row of the PLAN 12 table.
