# Memory map: out/app_deep.wasm

| Item | Value |
|---|---|
| File | out/app_deep.wasm, 38,476 B, sha256 59c2e3cbed173660 |
| Request mix | app_deep: one request, many, all waiting, many, overflow, no alloc, overflow, alloc, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed, unclean trap 1, unclean trap 2, unclean trap 3 |
| Map check | ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses) |
| Symbols | out/app_deep.map (93 data symbols); name section: 0 function names, 0 data names |
| Memory at start | 34 pages (2,228,224 B), maximum none; at the end 2,555,904 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 77, trap, clean: 4, cancelled (status 5): 3, trap, NOT clean: 2 |
| After the unclean traps | live bytes 0, canary ok 1 (12c: task_abort frees the pages and the slot of an unclean task, and the instance stays while the global check passes) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 0 |

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack, guard below the canary | 0x000000 | 0x002000 | 8,192 | yes: 102 of 8,192 B, 0x0000c0 to 0x001fb3; first in "overflow, no alloc" | 0 | 4. Shared stack |
| stack canary (4 KB, written by init) | 0x002000 | 0x003000 | 4,096 | no | 4096 | 7. Constant data (host constant) |
| shared stack | 0x003000 | 0x100000 | 1,036,288 | yes: 213,655 of 1,036,288 B, 0x003064 to 0x0ffffd; first in "one request" | 21 | 4. Shared stack |
| rodata (host), rodata (roc) | 0x100000 | 0x1001d0 | 464 | no | 0 | 7. Constant data |
| CPU flags of workerd, trap cause (5a, 5b) | 0x1001d0 | 0x1001d8 | 8 | no | 0 | 8. Host globals |
| task records | 0x1001d8 | 0x1005d8 | 1,024 | yes: 64 of 1,024 B, 0x1001dc to 0x1002d9; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| grow step (set once, before init), free mark (set once) | 0x1005d8 | 0x1005e0 | 8 | no | 4 | 8. Host globals |
| task records | 0x1005e0 | 0x1035e0 | 12,288 | yes: 390 of 12,288 B, 0x1005e8 to 0x101206; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| rodata (host) | 0x1035e0 | 0x1035f8 | 24 | no | 0 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x1035f8 | 0x1035fc | 4 | no | 0 | 8. Host globals |
| roc host table | 0x1035fc | 0x103618 | 28 | no | 0 | 7. Constant data |
| bench only: set_wild, poke_wait | 0x103618 | 0x103620 | 8 | no | 0 | none (bench only) |
| CPU flags of workerd, trap cause (5a, 5b) | 0x103620 | 0x103624 | 4 | yes: 1 of 4 B, 0x103620 to 0x103621; first in "faults" | 0 | 8. Host globals |
| allocator globals, counters, log | 0x103624 | 0x103634 | 16 | no | 0 | 8. Host globals |
| canary globals (init only) | 0x103634 | 0x103640 | 12 | no | 3 | 8. Host globals |
| allocator globals, counters, allocator counters of H3 and the idle reset (4h, 4j) | 0x103640 | 0x10364c | 12 | yes: 3 of 12 B, 0x103645 to 0x10364a; first in "one request" | 0 | 8. Host globals |
| pool bounds, unit tables (U_*) | 0x10364c | 0x113654 | 65,544 | yes: 135 of 65,544 B, 0x10364c to 0x10b8b6; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x113654 | 0x113658 | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), page reserve table | 0x113658 | 0x16b65c | 360,452 | yes: 194 of 360,452 B, 0x113878 to 0x16b659; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator counters of H3 and the idle reset (4h, 4j) | 0x16b65c | 0x16b664 | 8 | no | 0 | 8. Host globals |
| page reserve table, pool bounds, free-run index, unit tables (U_*) | 0x16b664 | 0x18c880 | 135,708 | yes: 281 of 135,708 B, 0x16b664 to 0x17cd43; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| allocator globals, counters | 0x18c880 | 0x18c884 | 4 | no | 0 | 8. Host globals |
| unit tables (U_*), task records, free-run index | 0x18c884 | 0x1d496c | 295,144 | yes: 250 of 295,144 B, 0x18ccc4 to 0x1d48ac; first in "one request" | 0 | 6. Allocator tables, task records, reserve table |
| trap flag | 0x1d496c | 0x1d4970 | 4 | no | 0 | 8. Host globals |
| export counter RUN_EPOCH (12b) | 0x1d4970 | 0x1d4974 | 4 | yes: 2 of 4 B, 0x1d4970 to 0x1d4972; first in "one request" | 1 | 8. Host globals |
| allocator counters of H3 and the idle reset (4h, 4j) | 0x1d4974 | 0x1d4980 | 12 | no | 0 | 8. Host globals |
| allocator globals, counters, host globals | 0x1d4980 | 0x1d49a0 | 32 | yes: 10 of 32 B, 0x1d4980 to 0x1d499e; first in "one request" | 1 | 8. Host globals |
| bench only: heap_fill | 0x1d49a0 | 0x2149a8 | 262,152 | yes: 2,749 of 262,152 B, 0x1d49a0 to 0x1d5947; first in "bench: heap_fill" | 0 | none (bench only) |
| WAITS (pointers to Wait records) | 0x2149a8 | 0x214da8 | 1,024 | yes: 223 of 1,024 B, 0x2149ae to 0x214af3; first in "many, all waiting" | 0 | 8. Host globals |
| sum of the constant data (12d, set by init) | 0x214da8 | 0x214db0 | 8 | no | 8 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x214db0 | 0x214db4 | 4 | no | 0 | 8. Host globals |
| bench only: fault_next_wait | 0x214db4 | 0x214db8 | 4 | no | 0 | none (bench only) |
| host globals | 0x214db8 | 0x214dbc | 4 | yes: 1 of 4 B, 0x214db8 to 0x214db9; first in "one request" | 0 | 8. Host globals |
| allocator globals, counters | 0x214dbc | 0x214dc0 | 4 | no | 1 | 8. Host globals |
| scratch bitmap of check_heap (cleared at each check) | 0x214dc0 | 0x215dc0 | 4,096 | yes: 10 of 4,096 B, 0x214e04 to 0x214e0e; first in "many, all waiting" | 0 | 6. Allocator tables, task records, reserve table |
| roc host table | 0x215dc0 | 0x215dc4 | 4 | no | 0 | 7. Constant data |
| sum mode, alarm counters (12a, 12b) | 0x215dc4 | 0x215dc8 | 4 | yes: 1 of 4 B, 0x215dc4 to 0x215dc5; first in "unclean trap 1" | 0 | 8. Host globals |
| bench only: leak_next, bench only: set_wild, poke_wait | 0x215dc8 | 0x215dd4 | 12 | no | 0 | none (bench only) |
| sum mode, alarm counters (12a, 12b) | 0x215dd4 | 0x215dd8 | 4 | yes: 1 of 4 B, 0x215dd4 to 0x215dd5; first in "one request" | 0 | 8. Host globals |
| bench only: set_wild, poke_wait | 0x215dd8 | 0x215de0 | 8 | no | 0 | none (bench only) |
| unused tail of the initial memory | 0x215de0 | 0x220000 | 41,504 | no | 0 | 5 (nobody writes it) |

## Heap (units of 4 KB, read from the unit tables)

Pool at the end: 0x220000 to 0x270000 (327,680 B). Counts are from the snapshot with 64 tasks waiting; "At idle" is the last snapshot with no task.

| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |
|---|---|---|---|---|---|---|
| free units | 0x261000 | 0x270000 | 15 | 61,440 | 14 | 5. Free units, page reserve |
| page reserve (empty small pages) | - | - | 0 | 0 | 66 | 5. Free units, page reserve |
| task small pages (64 task slots) | 0x221000 | 0x261000 | 64 | 262,144 | 0 | 1. Task pages and large blocks |
| task large blocks (41,984 B of it are 64 saved stack copies (row 2), found by the Wait records) | - | - | 0 | 0 | 0 | 1. Task pages and large blocks |
| host pages (slot 0) (Wait records (64 x 48 B), log lines; the response block is here for a short time) | 0x220000 | 0x221000 | 1 | 4,096 | 0 | 3. Wait record |
| JS pages (slot JS) (request blocks and response blocks of js_alloc) | - | - | 0 | 0 | 0 | 10. JS blocks |
| foreign units (roc runtime) | - | - | 0 | 0 | 0 | 9. Pages of the roc runtime (foreign units) |
| unit of kind none, not free, not reserve | - | - | 0 | 0 | 0 | none (empty) |
| response block of a task that ended (first request, from the return of handle to res_free) (in a host page) | 0x220000 | 0x220012 | 1 | 18 | - | 11. Response block of a task that ended |

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
| 0x100000 to 0x1001d0 | 464 | rodata (host), rodata (roc) |
| 0x1005d8 to 0x1005e0 | 8 | grow step (set once, before init), free mark (set once) |
| 0x1035e0 to 0x1035f8 | 24 | rodata (host) |
| 0x1035fc to 0x103618 | 28 | roc host table |
| 0x103634 to 0x103640 | 12 | canary globals (init only) |
| 0x214da8 to 0x214db0 | 8 | sum of the constant data (12d, set by init) |
| 0x215dc0 to 0x215dc4 | 4 | roc host table |
| Total, static | 4,644 | |
| Constant foreign units (unchanged after first seen) | 0 | 0 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| task records | yes: 64 of 1,024 B, 0x1001dc to 0x1002d9 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| task records | yes: 390 of 12,288 B, 0x1005e8 to 0x101206 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| CPU flags of workerd, trap cause (5a, 5b) | yes: 1 of 4 B, 0x103620 to 0x103621 | 8. Host globals | range check (12d) |
| allocator globals, counters, allocator counters of H3 and the idle reset (4h, 4j) | yes: 3 of 12 B, 0x103645 to 0x10364a | 8. Host globals | range check (12d) |
| pool bounds, unit tables (U_*) | yes: 135 of 65,544 B, 0x10364c to 0x10b8b6 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), page reserve table | yes: 194 of 360,452 B, 0x113878 to 0x16b659 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| page reserve table, pool bounds, free-run index, unit tables (U_*) | yes: 281 of 135,708 B, 0x16b664 to 0x17cd43 | 6. Allocator tables, task records, reserve table | structural check (12d) |
| unit tables (U_*), task records, free-run index | yes: 250 of 295,144 B, 0x18ccc4 to 0x1d48ac | 6. Allocator tables, task records, reserve table | structural check (12d) |
| export counter RUN_EPOCH (12b) | yes: 2 of 4 B, 0x1d4970 to 0x1d4972 | 8. Host globals | range check (12d) |
| allocator globals, counters, host globals | yes: 10 of 32 B, 0x1d4980 to 0x1d499e | 8. Host globals | range check (12d) |
| WAITS (pointers to Wait records) | yes: 223 of 1,024 B, 0x2149ae to 0x214af3 | 8. Host globals | range check (12d) |
| host globals | yes: 1 of 4 B, 0x214db8 to 0x214db9 | 8. Host globals | range check (12d) |
| scratch bitmap of check_heap (cleared at each check) | yes: 10 of 4,096 B, 0x214e04 to 0x214e0e | 6. Allocator tables, task records, reserve table | structural check (12d) |
| sum mode, alarm counters (12a, 12b) | yes: 1 of 4 B, 0x215dc4 to 0x215dc5 | 8. Host globals | range check (12d) |
| sum mode, alarm counters (12a, 12b) | yes: 1 of 4 B, 0x215dd4 to 0x215dd5 | 8. Host globals | range check (12d) |

## Detail: each symbol of the data and bss

| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |
|---|---|---|---|---|---|---|
| __anon_1664 | 0x100000 | 128 | .rodata | host | no | 7. Constant data |
| __anon_1178 | 0x100080 | 52 | .rodata | host | no | 7. Constant data |
| __anon_1812 | 0x1000b8 | 104 | .rodata | host | no | 7. Constant data |
| .roc.bytes.1 | 0x100120 | 33 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.2 | 0x100150 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_7829 | 0x10016b | 74 | .rodata | roc | no | 7. Constant data |
| __anon_8699 | 0x1001b5 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_10450 | 0x1001b8 | 12 | .rodata | roc | no | 7. Constant data |
| cpu.__instance_terminated | 0x1001d0 | 4 | .data | host | no | 8. Host globals |
| cpu.__instance_signal | 0x1001d4 | 4 | .data | host | no | 8. Host globals |
| alloc.SLOT_OWNER | 0x1001d8 | 1,024 | .data | host | yes: 64 of 1,024 B, 0x1001dc to 0x1002d9 | 6. Allocator tables, task records, reserve table |
| alloc.GROW_CHUNKS | 0x1005d8 | 4 | .data | host | no | 8. Host globals |
| alloc.FREE_MARK | 0x1005dc | 4 | .data | host | no | 8. Host globals |
| alloc.TASKS | 0x1005e0 | 12,288 | .data | host | yes: 390 of 12,288 B, 0x1005e8 to 0x101206 | 6. Allocator tables, task records, reserve table |
| __anon_2672 | 0x1035e0 | 8 | .data.rel.ro | host | no | 7. Constant data |
| alloc.vtable | 0x1035e8 | 16 | .data.rel.ro | host | no | 7. Constant data |
| host.SUM_MODE | 0x1035f8 | 4 | .data | host | no | 8. Host globals |
| roc.RocHostOf(roc_platform_abi.RocHost).host | 0x1035fc | 28 | .data | host | no | 7. Constant data |
| host.WILD_WORDS | 0x103618 | 4 | .data | host | no | none (bench only) |
| host.WILD_SEED | 0x10361c | 4 | .data | host | no | none (bench only) |
| cpu.CAUSE | 0x103620 | 4 | .bss | host | yes: 1 of 4 B, 0x103620 to 0x103621 | 8. Host globals |
| alloc.OWNER | 0x103624 | 4 | .bss | host | no | 8. Host globals |
| roc.LOG | 0x103628 | 12 | .bss | host | no | 8. Host globals |
| canary.STACK_LIMIT | 0x103634 | 4 | .bss | host | no | 8. Host globals |
| canary.CANARY_BASE | 0x103638 | 4 | .bss | host | no | 8. Host globals |
| canary.STACK_FIRST | 0x10363c | 1 | .bss | host | no | 8. Host globals |
| alloc.FAIL_AT | 0x103640 | 4 | .bss | host | no | 8. Host globals |
| alloc.LIVE_BYTES | 0x103644 | 4 | .bss | host | yes: 1 of 4 B, 0x103645 to 0x103646 | 8. Host globals |
| alloc.LIVE_PEAK | 0x103648 | 4 | .bss | host | yes: 2 of 4 B, 0x103648 to 0x10364a | 8. Host globals |
| alloc.POOL_LO | 0x10364c | 4 | .bss | host | yes: 2 of 4 B, 0x10364c to 0x10364e | 6. Allocator tables, task records, reserve table |
| alloc.POOL_HI | 0x103650 | 4 | .bss | host | yes: 2 of 4 B, 0x103650 to 0x103652 | 6. Allocator tables, task records, reserve table |
| alloc.U_KIND | 0x103654 | 32,768 | .bss | host | yes: 65 of 32,768 B, 0x103874 to 0x1038b5 | 6. Allocator tables, task records, reserve table |
| alloc.U_SLOT | 0x10b654 | 32,768 | .bss | host | yes: 66 of 32,768 B, 0x10b874 to 0x10b8b6 | 6. Allocator tables, task records, reserve table |
| alloc.DEALLOC_MISS | 0x113654 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_CLASS | 0x113658 | 32,768 | .bss | host | yes: 66 of 32,768 B, 0x113878 to 0x1138ba | 6. Allocator tables, task records, reserve table |
| alloc.U_UNITS | 0x11b658 | 65,536 | .bss | host | yes: 67 of 65,536 B, 0x11ba98 to 0x11bb1d | 6. Allocator tables, task records, reserve table |
| alloc.U_HW | 0x12b658 | 131,072 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_NEXT | 0x14b658 | 65,536 | .bss | host | yes: 30 of 65,536 B, 0x14bafc to 0x14bb1a | 6. Allocator tables, task records, reserve table |
| alloc.U_PREV | 0x15b658 | 65,536 | .bss | host | yes: 30 of 65,536 B, 0x15bafa to 0x15bb1a | 6. Allocator tables, task records, reserve table |
| alloc.CACHED | 0x16b658 | 4 | .bss | host | yes: 1 of 4 B, 0x16b658 to 0x16b659 | 6. Allocator tables, task records, reserve table |
| alloc.RECLAIMS | 0x16b65c | 4 | .bss | host | no | 8. Host globals |
| alloc.RECLAIMED | 0x16b660 | 4 | .bss | host | no | 8. Host globals |
| alloc.CACHE | 0x16b664 | 512 | .bss | host | yes: 132 of 512 B, 0x16b664 to 0x16b6e8 | 6. Allocator tables, task records, reserve table |
| alloc.CHUNKS_USED | 0x16b864 | 4 | .bss | host | yes: 1 of 4 B, 0x16b864 to 0x16b865 | 6. Allocator tables, task records, reserve table |
| alloc.FREE_BITS | 0x16b868 | 4,096 | .bss | host | yes: 4 of 4,096 B, 0x16b8ac to 0x16b8b6 | 6. Allocator tables, task records, reserve table |
| alloc.U_START | 0x16c868 | 65,536 | .bss | host | yes: 10 of 65,536 B, 0x16ccc6 to 0x16cd48 | 6. Allocator tables, task records, reserve table |
| alloc.GROWN_END | 0x17c868 | 4 | .bss | host | yes: 1 of 4 B, 0x17c86a to 0x17c86b | 6. Allocator tables, task records, reserve table |
| alloc.RL_FLBITS | 0x17c86c | 2 | .bss | host | yes: 1 of 2 B, 0x17c86c to 0x17c86d | 6. Allocator tables, task records, reserve table |
| alloc.RL_SLBITS | 0x17c86e | 14 | .bss | host | yes: 1 of 14 B, 0x17c86f to 0x17c870 | 6. Allocator tables, task records, reserve table |
| alloc.LOW_HINT | 0x17c87c | 4 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_BUMP | 0x17c880 | 65,536 | .bss | host | yes: 131 of 65,536 B, 0x17ccc0 to 0x17cd43 | 6. Allocator tables, task records, reserve table |
| alloc.DOUBLE_FREES | 0x18c880 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_FREE | 0x18c884 | 65,536 | .bss | host | yes: 82 of 65,536 B, 0x18ccc4 to 0x18cd47 | 6. Allocator tables, task records, reserve table |
| alloc.U_INAV | 0x19c884 | 32,768 | .bss | host | yes: 65 of 32,768 B, 0x19caa4 to 0x19cae5 | 6. Allocator tables, task records, reserve table |
| alloc.U_LIVE | 0x1a4884 | 65,536 | .bss | host | yes: 65 of 65,536 B, 0x1a4cc4 to 0x1a4d45 | 6. Allocator tables, task records, reserve table |
| alloc.U_ANEXT | 0x1b4884 | 65,536 | .bss | host | yes: 30 of 65,536 B, 0x1b4d26 to 0x1b4d46 | 6. Allocator tables, task records, reserve table |
| alloc.U_APREV | 0x1c4884 | 65,536 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.LAST_OWNER | 0x1d4884 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4884 to 0x1d4885 | 6. Allocator tables, task records, reserve table |
| alloc.LAST_SLOT | 0x1d4888 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4888 to 0x1d4889 | 6. Allocator tables, task records, reserve table |
| alloc.RL_HEAD | 0x1d488c | 224 | .bss | host | yes: 6 of 224 B, 0x1d48a6 to 0x1d48ac | 6. Allocator tables, task records, reserve table |
| mem.TRAP_CLEAN | 0x1d496c | 1 | .bss | host | no | 8. Host globals |
| mem.RUN_EPOCH | 0x1d4970 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4970 to 0x1d4972 | 8. Host globals |
| alloc.RESET_BYTES | 0x1d4974 | 4 | .bss | host | no | 8. Host globals |
| alloc.RESETS | 0x1d4978 | 4 | .bss | host | no | 8. Host globals |
| alloc.LEAKED | 0x1d497c | 4 | .bss | host | no | 8. Host globals |
| alloc.ROC_BYTES | 0x1d4980 | 4 | .bss | host | yes: 3 of 4 B, 0x1d4980 to 0x1d4983 | 8. Host globals |
| host.TASK_TOP | 0x1d4984 | 4 | .bss | host | no | 8. Host globals |
| host.TASK_WAITING | 0x1d4988 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4988 to 0x1d4989 | 8. Host globals |
| host.COPY | 0x1d498c | 1 | .bss | host | no | 8. Host globals |
| host.TASK_WAITS | 0x1d4990 | 4 | .bss | host | yes: 1 of 4 B, 0x1d4990 to 0x1d4991 | 8. Host globals |
| host.TASK_SAVED_MAX | 0x1d4994 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4994 to 0x1d4996 | 8. Host globals |
| host.TASK_SAVED_PEAK | 0x1d4998 | 4 | .bss | host | yes: 2 of 4 B, 0x1d4998 to 0x1d499a | 8. Host globals |
| host.TASK_SAVED | 0x1d499c | 4 | .bss | host | yes: 1 of 4 B, 0x1d499d to 0x1d499e | 8. Host globals |
| host.FILL_TAG | 0x1d49a0 | 4 | .bss | host | yes: 1 of 4 B, 0x1d49a0 to 0x1d49a1 | none (bench only) |
| host.FILLED | 0x1d49a4 | 4 | .bss | host | yes: 2 of 4 B, 0x1d49a4 to 0x1d49a6 | none (bench only) |
| host.FILL | 0x1d49a8 | 262,144 | .bss | host | yes: 2,746 of 262,144 B, 0x1d49a9 to 0x1d5947 | none (bench only) |
| host.WAITS | 0x2149a8 | 1,024 | .bss | host | yes: 223 of 1,024 B, 0x2149ae to 0x214af3 | 8. Host globals |
| host.CONST_SUM | 0x214da8 | 8 | .bss | host | no | 7. Constant data |
| host.SUSPECT | 0x214db0 | 1 | .bss | host | no | 8. Host globals |
| host.FAULT_NEXT | 0x214db4 | 4 | .bss | host | no | none (bench only) |
| host.WAITS_FREE_HINT | 0x214db8 | 4 | .bss | host | yes: 1 of 4 B, 0x214db8 to 0x214db9 | 8. Host globals |
| alloc.INIT_MEM_END | 0x214dbc | 4 | .bss | host | no | 8. Host globals |
| alloc.SEEN | 0x214dc0 | 4,096 | .bss | host | yes: 10 of 4,096 B, 0x214e04 to 0x214e0e | 6. Allocator tables, task records, reserve table |
| roc.RocHostOf(roc_platform_abi.RocHost).env | 0x215dc0 | 1 | .bss | host | no | 7. Constant data |
| host.ALARMS | 0x215dc4 | 4 | .bss | host | yes: 1 of 4 B, 0x215dc4 to 0x215dc5 | 8. Host globals |
| host.LEAK_NEXT | 0x215dc8 | 4 | .bss | host | no | none (bench only) |
| host.POKE_OUT | 0x215dcc | 4 | .bss | host | no | none (bench only) |
| host.WILD_TRAP | 0x215dd0 | 4 | .bss | host | no | none (bench only) |
| host.SUM_CHECKS | 0x215dd4 | 4 | .bss | host | yes: 1 of 4 B, 0x215dd4 to 0x215dd5 | 8. Host globals |
| host.POKE_OUT_ADD | 0x215dd8 | 4 | .bss | host | no | none (bench only) |
| host.WILD_BASE | 0x215ddc | 4 | .bss | host | no | none (bench only) |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | CPU flags of workerd, trap cause (5a, 5b); sum mode, alarm counters (12a, 12b); allocator globals, counters, log; allocator globals, counters; allocator counters of H3 and the idle reset (4h, 4j); allocator globals, counters; trap flag; allocator counters of H3 and the idle reset (4h, 4j); sum mode, alarm counters (12a, 12b); allocator globals, counters |
| Regions with no PLAN 12 row | none |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| check_heap (12d) after a flip of each byte of the constant symbols and the canary | 4606 of 4606 found (codes 12: 4605, trap: 1); after the last flip back: 0 |
| check_heap (12d) after each phase | 0 (pass) in all 8 phases |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: set_wild, poke_wait, 8 B; bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B; bench only: leak_next, bench only: set_wild, poke_wait, 12 B; bench only: set_wild, poke_wait, 8 B |

RESULT: every region is in a row of the PLAN 12 table.
