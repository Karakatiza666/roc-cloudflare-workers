# Memory map: out/app.wasm

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

## Detail: each symbol of the data and bss

| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |
|---|---|---|---|---|---|---|
| __anon_1652 | 0x100000 | 128 | .rodata | host | no | 7. Constant data |
| __anon_1166 | 0x100080 | 52 | .rodata | host | no | 7. Constant data |
| __anon_1767 | 0x1000b8 | 104 | .rodata | host | no | 7. Constant data |
| __anon_1994 | 0x100120 | 8 | .rodata | host | no | 7. Constant data |
| .roc.bytes.0 | 0x100130 | 19 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.1 | 0x100150 | 27 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.3 | 0x100170 | 21 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.4 | 0x100190 | 64 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.5 | 0x1001d0 | 33 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.6 | 0x100200 | 30 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.7 | 0x100220 | 17 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.8 | 0x100240 | 25 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.9 | 0x100259 | 12 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.10 | 0x100270 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_7829 | 0x10028b | 74 | .rodata | roc | no | 7. Constant data |
| __anon_8699 | 0x1002d5 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_10450 | 0x1002d8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_10522 | 0x1002e4 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10523 | 0x1002e8 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10524 | 0x1002ec | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10525 | 0x1002f0 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10527 | 0x1002f4 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10675 | 0x1002f8 | 256 | .rodata | roc | no | 7. Constant data |
| alloc.FREE_MARK | 0x100400 | 4 | .data | host | no | 8. Host globals |
| alloc.SLOT_OWNER | 0x100404 | 1,024 | .data | host | yes: 64 of 1,024 B, 0x100408 to 0x100505 | 6. Allocator tables, task records, reserve table |
| alloc.TASKS | 0x100810 | 12,288 | .data | host | yes: 658 of 12,288 B, 0x100818 to 0x1037f4 | 6. Allocator tables, task records, reserve table |
| __anon_2300 | 0x103810 | 8 | .data.rel.ro | host | no | 7. Constant data |
| alloc.vtable | 0x103818 | 16 | .data.rel.ro | host | no | 7. Constant data |
| roc.RocHostOf(roc_platform_abi.RocHost).host | 0x103828 | 28 | .data | host | no | 7. Constant data |
| alloc.OWNER | 0x103850 | 4 | .bss | host | no | 8. Host globals |
| roc.LOG | 0x103854 | 12 | .bss | host | no | 8. Host globals |
| canary.STACK_LIMIT | 0x103860 | 4 | .bss | host | no | 8. Host globals |
| canary.CANARY_BASE | 0x103864 | 4 | .bss | host | no | 8. Host globals |
| canary.STACK_FIRST | 0x103868 | 1 | .bss | host | no | 8. Host globals |
| alloc.FAIL_AT | 0x10386c | 4 | .bss | host | no | 8. Host globals |
| alloc.LIVE_BYTES | 0x103870 | 4 | .bss | host | yes: 3 of 4 B, 0x103870 to 0x103873 | 8. Host globals |
| alloc.POOL_LO | 0x103874 | 4 | .bss | host | yes: 2 of 4 B, 0x103874 to 0x103876 | 6. Allocator tables, task records, reserve table |
| alloc.POOL_HI | 0x103878 | 4 | .bss | host | yes: 2 of 4 B, 0x103878 to 0x10387a | 6. Allocator tables, task records, reserve table |
| alloc.U_KIND | 0x10387c | 32,768 | .bss | host | yes: 2,947 of 32,768 B, 0x103a9e to 0x1046ac | 6. Allocator tables, task records, reserve table |
| alloc.U_CLASS | 0x10b87c | 32,768 | .bss | host | yes: 269 of 32,768 B, 0x10ba9c to 0x10c54d | 6. Allocator tables, task records, reserve table |
| alloc.U_UNITS | 0x11387c | 65,536 | .bss | host | yes: 814 of 65,536 B, 0x113cbc to 0x1154d1 | 6. Allocator tables, task records, reserve table |
| alloc.U_HW | 0x12387c | 131,072 | .bss | host | yes: 326 of 131,072 B, 0x12416c to 0x127126 | 6. Allocator tables, task records, reserve table |
| alloc.U_SLOT | 0x14387c | 32,768 | .bss | host | yes: 488 of 32,768 B, 0x143a9c to 0x1446a7 | 6. Allocator tables, task records, reserve table |
| alloc.U_NEXT | 0x14b87c | 65,536 | .bss | host | yes: 808 of 65,536 B, 0x14bcbc to 0x14d4d2 | 6. Allocator tables, task records, reserve table |
| alloc.U_PREV | 0x15b87c | 65,536 | .bss | host | yes: 780 of 65,536 B, 0x15bcbc to 0x15d49e | 6. Allocator tables, task records, reserve table |
| alloc.CACHED | 0x16b87c | 4 | .bss | host | yes: 2 of 4 B, 0x16b87c to 0x16b87e | 6. Allocator tables, task records, reserve table |
| alloc.CACHE | 0x16b880 | 512 | .bss | host | yes: 512 of 512 B, 0x16b880 to 0x16ba80 | 6. Allocator tables, task records, reserve table |
| alloc.CHUNKS_USED | 0x16ba80 | 4 | .bss | host | yes: 2 of 4 B, 0x16ba80 to 0x16ba82 | 6. Allocator tables, task records, reserve table |
| alloc.FREE_BITS | 0x16ba88 | 4,096 | .bss | host | yes: 371 of 4,096 B, 0x16bacc to 0x16bc4e | 6. Allocator tables, task records, reserve table |
| alloc.U_START | 0x16ca88 | 65,536 | .bss | host | yes: 640 of 65,536 B, 0x16cece to 0x16e6e8 | 6. Allocator tables, task records, reserve table |
| alloc.GROWN_END | 0x17ca88 | 4 | .bss | host | yes: 1 of 4 B, 0x17ca8a to 0x17ca8b | 6. Allocator tables, task records, reserve table |
| alloc.RL_FLBITS | 0x17ca8c | 2 | .bss | host | yes: 1 of 2 B, 0x17ca8c to 0x17ca8d | 6. Allocator tables, task records, reserve table |
| alloc.RL_SLBITS | 0x17ca8e | 14 | .bss | host | yes: 6 of 14 B, 0x17ca8e to 0x17ca95 | 6. Allocator tables, task records, reserve table |
| alloc.LOW_HINT | 0x17ca9c | 4 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_BUMP | 0x17caa0 | 65,536 | .bss | host | yes: 474 of 65,536 B, 0x17cee0 to 0x17e442 | 6. Allocator tables, task records, reserve table |
| alloc.DOUBLE_FREES | 0x18caa0 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_FREE | 0x18caa4 | 65,536 | .bss | host | yes: 431 of 65,536 B, 0x18cee4 to 0x18e445 | 6. Allocator tables, task records, reserve table |
| alloc.U_INAV | 0x19caa4 | 32,768 | .bss | host | yes: 137 of 32,768 B, 0x19ccc6 to 0x19d773 | 6. Allocator tables, task records, reserve table |
| alloc.U_LIVE | 0x1a4aa4 | 65,536 | .bss | host | yes: 147 of 65,536 B, 0x1a4ee8 to 0x1a6441 | 6. Allocator tables, task records, reserve table |
| alloc.U_ANEXT | 0x1b4aa4 | 65,536 | .bss | host | yes: 308 of 65,536 B, 0x1b4ee4 to 0x1b6444 | 6. Allocator tables, task records, reserve table |
| alloc.U_APREV | 0x1c4aa4 | 65,536 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.LAST_OWNER | 0x1d4aa4 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4aa4 to 0x1d4aa5 | 6. Allocator tables, task records, reserve table |
| alloc.LAST_SLOT | 0x1d4aa8 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4aa8 to 0x1d4aa9 | 6. Allocator tables, task records, reserve table |
| alloc.RL_HEAD | 0x1d4aac | 224 | .bss | host | yes: 36 of 224 B, 0x1d4aae to 0x1d4b12 | 6. Allocator tables, task records, reserve table |
| mem.TRAP_CLEAN | 0x1d4b8c | 1 | .bss | host | no | 8. Host globals |
| alloc.DEALLOC_MISS | 0x1d4b90 | 4 | .bss | host | no | 8. Host globals |
| alloc.ROC_BYTES | 0x1d4b94 | 4 | .bss | host | yes: 4 of 4 B, 0x1d4b94 to 0x1d4b98 | 8. Host globals |
| host.COPY | 0x1d4b98 | 1 | .bss | host | no | 8. Host globals |
| host.TASK_WAITS | 0x1d4b9c | 4 | .bss | host | yes: 1 of 4 B, 0x1d4b9c to 0x1d4b9d | 8. Host globals |
| host.TASK_SAVED_MAX | 0x1d4ba0 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4ba0 to 0x1d4ba3 | 8. Host globals |
| host.TASK_SAVED_PEAK | 0x1d4ba4 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4ba4 to 0x1d4ba7 | 8. Host globals |
| host.TASK_SAVED | 0x1d4ba8 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4ba8 to 0x1d4bab | 8. Host globals |
| host.TASK_WAITING | 0x1d4bac | 4 | .bss | host | yes: 1 of 4 B, 0x1d4bac to 0x1d4bad | 8. Host globals |
| host.FILL_TAG | 0x1d4bb0 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4bb0 to 0x1d4bb1 | none (bench only) |
| host.FILLED | 0x1d4bb4 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4bb4 to 0x1d4bb6 | none (bench only) |
| host.FILL | 0x1d4bb8 | 262,144 | .bss | host | yes: 2,750 of 262,144 B, 0x1d4bb9 to 0x1d5b57 | none (bench only) |
| host.WAITS | 0x214bb8 | 1,024 | .bss | host | yes: 253 of 1,024 B, 0x214be1 to 0x214e3f | 8. Host globals |
| host.TASK_TOP | 0x214fb8 | 4 | .bss | host | no | 8. Host globals |
| host.FAULT_NEXT | 0x214fbc | 4 | .bss | host | no | none (bench only) |
| host.WAITS_FREE_HINT | 0x214fc0 | 4 | .bss | host | yes: 1 of 4 B, 0x214fc0 to 0x214fc1 | 8. Host globals |
| roc.RocHostOf(roc_platform_abi.RocHost).env | 0x214fc4 | 1 | .bss | host | no | 7. Constant data |
| roc_tail_pending | 0x214fc8 | 4 | .bss | roc | no | NONE |
| roc_tail_args | 0x214fd0 | 208 | .bss | roc | yes: 52 of 208 B, 0x214fd0 to 0x21508c | NONE |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | Roc side statics (.bss) |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: 1 region(s) are not in the table.
