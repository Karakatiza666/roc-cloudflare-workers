# Memory map: out/app_boxy.wasm

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

## Detail: each symbol of the data and bss

| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |
|---|---|---|---|---|---|---|
| __anon_1652 | 0x100000 | 128 | .rodata | host | no | 7. Constant data |
| __anon_1166 | 0x100080 | 52 | .rodata | host | no | 7. Constant data |
| __anon_1767 | 0x1000b8 | 104 | .rodata | host | no | 7. Constant data |
| __anon_1994 | 0x100120 | 8 | .rodata | host | no | 7. Constant data |
| .roc.bytes.0 | 0x100130 | 19 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.1 | 0x100150 | 27 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.2 | 0x100170 | 17 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.3 | 0x100190 | 25 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.4 | 0x1001a9 | 12 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.5 | 0x1001c0 | 20 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.6 | 0x1001e0 | 27 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.7 | 0x100200 | 21 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.8 | 0x100220 | 64 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.9 | 0x100260 | 21 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.10 | 0x100280 | 33 | .rodata | roc | no | 7. Constant data |
| .roc.bytes.11 | 0x1002b0 | 30 | .rodata | roc | no | 7. Constant data |
| __anon_7829 | 0x1002ce | 74 | .rodata | roc | no | 7. Constant data |
| __anon_8699 | 0x100318 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_10450 | 0x100320 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_10522 | 0x10032c | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10523 | 0x100330 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10524 | 0x100334 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10525 | 0x100338 | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10527 | 0x10033c | 4 | .rodata | roc | no | 7. Constant data |
| __anon_10675 | 0x100340 | 256 | .rodata | roc | no | 7. Constant data |
| __anon_3058 | 0x100440 | 74 | .rodata | roc | no | 7. Constant data |
| __anon_3302 | 0x10048c | 4 | .rodata | roc | no | 7. Constant data |
| __anon_3359 | 0x100490 | 40 | .rodata | roc | no | 7. Constant data |
| __anon_3368 | 0x1004b8 | 40 | .rodata | roc | no | 7. Constant data |
| __anon_3999 | 0x1004e0 | 8 | .rodata | roc | no | 7. Constant data |
| __anon_4055 | 0x1004e8 | 39 | .rodata | roc | no | 7. Constant data |
| __anon_4064 | 0x10050f | 10 | .rodata | roc | no | 7. Constant data |
| __anon_4068 | 0x100519 | 13 | .rodata | roc | no | 7. Constant data |
| __anon_4072 | 0x100526 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_4122 | 0x10053e | 2 | .rodata | roc | no | 7. Constant data |
| __anon_4128 | 0x100540 | 3 | .rodata | roc | no | 7. Constant data |
| __anon_4133 | 0x100543 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_4788 | 0x100548 | 28 | .rodata | roc | no | 7. Constant data |
| __anon_5022 | 0x100564 | 16 | .rodata | roc | no | 7. Constant data |
| __anon_5084 | 0x100574 | 28 | .rodata | roc | no | 7. Constant data |
| __anon_5669 | 0x100590 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5674 | 0x1005a8 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5675 | 0x1005c0 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5676 | 0x1005d8 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5685 | 0x1005f0 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5686 | 0x100608 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5687 | 0x100620 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_5733 | 0x100638 | 52 | .rodata | roc | no | 7. Constant data |
| __anon_5758 | 0x10066c | 44 | .rodata | roc | no | 7. Constant data |
| __anon_6523 | 0x100698 | 57 | .rodata | roc | no | 7. Constant data |
| __anon_6624 | 0x1006d1 | 62 | .rodata | roc | no | 7. Constant data |
| __anon_8559 | 0x10070f | 52 | .rodata | roc | no | 7. Constant data |
| __anon_9293 | 0x100743 | 48 | .rodata | roc | no | 7. Constant data |
| __anon_9311 | 0x100773 | 54 | .rodata | roc | no | 7. Constant data |
| __anon_9321 | 0x1007a9 | 54 | .rodata | roc | no | 7. Constant data |
| __anon_9336 | 0x1007df | 49 | .rodata | roc | no | 7. Constant data |
| __anon_9448 | 0x100810 | 64 | .rodata | roc | no | 7. Constant data |
| __anon_9459 | 0x100850 | 61 | .rodata | roc | no | 7. Constant data |
| __anon_9465 | 0x10088d | 11 | .rodata | roc | no | 7. Constant data |
| __anon_9469 | 0x100898 | 2 | .rodata | roc | no | 7. Constant data |
| __anon_9477 | 0x10089a | 61 | .rodata | roc | no | 7. Constant data |
| __anon_9481 | 0x1008d7 | 26 | .rodata | roc | no | 7. Constant data |
| __anon_9485 | 0x1008f1 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_9489 | 0x10090c | 18 | .rodata | roc | no | 7. Constant data |
| __anon_9497 | 0x10091e | 65 | .rodata | roc | no | 7. Constant data |
| __anon_9501 | 0x10095f | 2 | .rodata | roc | no | 7. Constant data |
| __anon_9509 | 0x100961 | 57 | .rodata | roc | no | 7. Constant data |
| __anon_9520 | 0x10099a | 51 | .rodata | roc | no | 7. Constant data |
| __anon_9759 | 0x1009d0 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_9768 | 0x1009dc | 12 | .rodata | roc | no | 7. Constant data |
| __anon_9782 | 0x1009e8 | 74 | .rodata | roc | no | 7. Constant data |
| __anon_9923 | 0x100a38 | 8 | .rodata | roc | no | 7. Constant data |
| __anon_9930 | 0x100a40 | 55 | .rodata | roc | no | 7. Constant data |
| __anon_9943 | 0x100a77 | 47 | .rodata | roc | no | 7. Constant data |
| __anon_9956 | 0x100aa6 | 58 | .rodata | roc | no | 7. Constant data |
| __anon_9961 | 0x100ae0 | 49 | .rodata | roc | no | 7. Constant data |
| __anon_10081 | 0x100b11 | 56 | .rodata | roc | no | 7. Constant data |
| __anon_10093 | 0x100b49 | 63 | .rodata | roc | no | 7. Constant data |
| __anon_10102 | 0x100b88 | 58 | .rodata | roc | no | 7. Constant data |
| __anon_10110 | 0x100bc2 | 54 | .rodata | roc | no | 7. Constant data |
| __anon_10122 | 0x100bf8 | 47 | .rodata | roc | no | 7. Constant data |
| __anon_10169 | 0x100c27 | 52 | .rodata | roc | no | 7. Constant data |
| __anon_10177 | 0x100c5b | 55 | .rodata | roc | no | 7. Constant data |
| __anon_10185 | 0x100c92 | 46 | .rodata | roc | no | 7. Constant data |
| __anon_10211 | 0x100cc0 | 48 | .rodata | roc | no | 7. Constant data |
| __anon_10220 | 0x100cf0 | 49 | .rodata | roc | no | 7. Constant data |
| __anon_10258 | 0x100d21 | 45 | .rodata | roc | no | 7. Constant data |
| __anon_10266 | 0x100d4e | 38 | .rodata | roc | no | 7. Constant data |
| __anon_10486 | 0x100d74 | 61 | .rodata | roc | no | 7. Constant data |
| __anon_10546 | 0x100db1 | 63 | .rodata | roc | no | 7. Constant data |
| __anon_10696 | 0x100df0 | 59 | .rodata | roc | no | 7. Constant data |
| __anon_10706 | 0x100e2b | 57 | .rodata | roc | no | 7. Constant data |
| __anon_10714 | 0x100e64 | 54 | .rodata | roc | no | 7. Constant data |
| __anon_10722 | 0x100e9a | 50 | .rodata | roc | no | 7. Constant data |
| __anon_10740 | 0x100ecc | 64 | .rodata | roc | no | 7. Constant data |
| __anon_10752 | 0x100f0c | 48 | .rodata | roc | no | 7. Constant data |
| __anon_10970 | 0x100f3c | 65 | .rodata | roc | no | 7. Constant data |
| __anon_10978 | 0x100f7d | 57 | .rodata | roc | no | 7. Constant data |
| __anon_11184 | 0x100fb8 | 32 | .rodata | roc | no | 7. Constant data |
| __anon_11456 | 0x100fd8 | 63 | .rodata | roc | no | 7. Constant data |
| __anon_11473 | 0x101017 | 56 | .rodata | roc | no | 7. Constant data |
| __anon_11802 | 0x10104f | 47 | .rodata | roc | no | 7. Constant data |
| __anon_12414 | 0x10107e | 25 | .rodata | roc | no | 7. Constant data |
| __anon_12422 | 0x101097 | 54 | .rodata | roc | no | 7. Constant data |
| __anon_12430 | 0x1010cd | 37 | .rodata | roc | no | 7. Constant data |
| __anon_12465 | 0x1010f2 | 53 | .rodata | roc | no | 7. Constant data |
| __anon_12477 | 0x101127 | 27 | .rodata | roc | no | 7. Constant data |
| __anon_12486 | 0x101144 | 8 | .rodata | roc | no | 7. Constant data |
| __anon_12532 | 0x10114c | 37 | .rodata | roc | no | 7. Constant data |
| __anon_12540 | 0x101171 | 26 | .rodata | roc | no | 7. Constant data |
| __anon_12569 | 0x10118b | 61 | .rodata | roc | no | 7. Constant data |
| __anon_12603 | 0x1011c8 | 61 | .rodata | roc | no | 7. Constant data |
| __anon_12752 | 0x101205 | 24 | .rodata | roc | no | 7. Constant data |
| __anon_17604 | 0x10121d | 49 | .rodata | roc | no | 7. Constant data |
| __anon_17643 | 0x10124e | 49 | .rodata | roc | no | 7. Constant data |
| __anon_18185 | 0x101280 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18192 | 0x10128c | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18196 | 0x101298 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18200 | 0x1012a4 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18204 | 0x1012b0 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18222 | 0x1012bc | 60 | .rodata | roc | no | 7. Constant data |
| __anon_18895 | 0x1012f8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18910 | 0x101308 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18928 | 0x101318 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18943 | 0x101328 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18958 | 0x101338 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18973 | 0x101348 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_18988 | 0x101358 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19003 | 0x101368 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19011 | 0x101378 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19026 | 0x101388 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19041 | 0x101398 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19046 | 0x1013a8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19061 | 0x1013b8 | 28 | .rodata | roc | no | 7. Constant data |
| __anon_19087 | 0x1013d8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19102 | 0x1013e8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19107 | 0x1013f8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19112 | 0x101408 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19117 | 0x101418 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19122 | 0x101428 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19137 | 0x101438 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19152 | 0x101448 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19167 | 0x101458 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19182 | 0x101468 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19204 | 0x101478 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19219 | 0x101488 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19233 | 0x101498 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19248 | 0x1014a8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19253 | 0x1014b8 | 12 | .rodata | roc | no | 7. Constant data |
| __anon_19268 | 0x1014c8 | 40 | .rodata | roc | no | 7. Constant data |
| __anon_19942 | 0x1014f0 | 8 | .rodata | roc | no | 7. Constant data |
| __anon_19266 | 0x1014f8 | 12 | .rodata | roc | no | 7. Constant data |
| heap.BrkAllocator.vtable | 0x101504 | 16 | .rodata | roc | no | 7. Constant data |
| switch.table.boxy_abi.AbiHooks.rcPlanFor | 0x101514 | 16 | .rodata | roc | no | 7. Constant data |
| switch.table.boxy_abi.AbiHooks.rcPlanFor.1060 | 0x101524 | 16 | .rodata | roc | no | 7. Constant data |
| alloc.FREE_MARK | 0x101540 | 4 | .data | host | no | 8. Host globals |
| alloc.SLOT_OWNER | 0x101544 | 1,024 | .data | host | yes: 24 of 1,024 B, 0x101548 to 0x1015a5 | 6. Allocator tables, task records, reserve table |
| alloc.TASKS | 0x101950 | 12,288 | .data | host | yes: 258 of 12,288 B, 0x101958 to 0x104934 | 6. Allocator tables, task records, reserve table |
| __anon_2300 | 0x104950 | 8 | .data.rel.ro | host | no | 7. Constant data |
| alloc.vtable | 0x104958 | 16 | .data.rel.ro | host | no | 7. Constant data |
| roc.RocHostOf(roc_platform_abi.RocHost).host | 0x104968 | 28 | .data | host | no | 7. Constant data |
| in_process_host.symbol_backed_ops | 0x104984 | 36 | .data | roc | no | NONE |
| in_process_host.no_hosted_fns | 0x1049a8 | 4 | .data | roc | no | NONE |
| in_process_host.symbol_backed_ops | 0x1049ac | 36 | .data | roc | no | NONE |
| in_process_host.no_hosted_fns | 0x1049d0 | 4 | .data | roc | no | NONE |
| boxy_abi.TailStateSelection__struct_535.state | 0x1049d4 | 88 | .data | roc | yes: 10 of 88 B, 0x104a10 to 0x104a25 | NONE |
| roc_boxy_sidecar_blob | 0x104a30 | 825,564 | roc_boxy_sidecar_blob | roc | no | 7. Constant data |
| roc_boxy_sidecar_blob_len | 0x1ce310 | 8 | roc_boxy_sidecar_blob_len | roc | no | 7. Constant data |
| roc_boxy_sidecar_desc | 0x1ce318 | 720 | roc_boxy_sidecar_desc | roc | no | 7. Constant data |
| alloc.OWNER | 0x1ce5e8 | 4 | .bss | host | no | 8. Host globals |
| roc.LOG | 0x1ce5ec | 12 | .bss | host | no | 8. Host globals |
| canary.STACK_LIMIT | 0x1ce5f8 | 4 | .bss | host | no | 8. Host globals |
| canary.CANARY_BASE | 0x1ce5fc | 4 | .bss | host | no | 8. Host globals |
| canary.STACK_FIRST | 0x1ce600 | 1 | .bss | host | no | 8. Host globals |
| alloc.FAIL_AT | 0x1ce604 | 4 | .bss | host | no | 8. Host globals |
| alloc.LIVE_BYTES | 0x1ce608 | 4 | .bss | host | yes: 3 of 4 B, 0x1ce608 to 0x1ce60b | 8. Host globals |
| alloc.POOL_LO | 0x1ce60c | 4 | .bss | host | yes: 2 of 4 B, 0x1ce60c to 0x1ce60e | 6. Allocator tables, task records, reserve table |
| alloc.POOL_HI | 0x1ce610 | 4 | .bss | host | yes: 2 of 4 B, 0x1ce610 to 0x1ce612 | 6. Allocator tables, task records, reserve table |
| alloc.U_KIND | 0x1ce614 | 32,768 | .bss | host | yes: 1,339 of 32,768 B, 0x1ce8f4 to 0x1cee34 | 6. Allocator tables, task records, reserve table |
| alloc.U_CLASS | 0x1d6614 | 32,768 | .bss | host | yes: 57 of 32,768 B, 0x1d68f4 to 0x1d6d76 | 6. Allocator tables, task records, reserve table |
| alloc.U_UNITS | 0x1de614 | 65,536 | .bss | host | yes: 205 of 65,536 B, 0x1debd4 to 0x1df651 | 6. Allocator tables, task records, reserve table |
| alloc.U_HW | 0x1ee614 | 131,072 | .bss | host | yes: 143 of 131,072 B, 0x1ef85c to 0x1f065e | 6. Allocator tables, task records, reserve table |
| alloc.U_SLOT | 0x20e614 | 32,768 | .bss | host | yes: 202 of 32,768 B, 0x20e8f4 to 0x20ee33 | 6. Allocator tables, task records, reserve table |
| alloc.U_NEXT | 0x216614 | 65,536 | .bss | host | yes: 331 of 65,536 B, 0x216bd4 to 0x217652 | 6. Allocator tables, task records, reserve table |
| alloc.U_PREV | 0x226614 | 65,536 | .bss | host | yes: 316 of 65,536 B, 0x226bd4 to 0x227652 | 6. Allocator tables, task records, reserve table |
| alloc.CACHED | 0x236614 | 4 | .bss | host | yes: 1 of 4 B, 0x236614 to 0x236615 | 6. Allocator tables, task records, reserve table |
| alloc.CACHE | 0x236618 | 512 | .bss | host | yes: 118 of 512 B, 0x236618 to 0x23668e | 6. Allocator tables, task records, reserve table |
| alloc.CHUNKS_USED | 0x236818 | 4 | .bss | host | yes: 2 of 4 B, 0x236818 to 0x23681a | 6. Allocator tables, task records, reserve table |
| alloc.FREE_BITS | 0x236820 | 4,096 | .bss | host | yes: 54 of 4,096 B, 0x23687d to 0x236924 | 6. Allocator tables, task records, reserve table |
| alloc.U_START | 0x237820 | 65,536 | .bss | host | yes: 364 of 65,536 B, 0x237df6 to 0x238860 | 6. Allocator tables, task records, reserve table |
| alloc.GROWN_END | 0x247820 | 4 | .bss | host | yes: 1 of 4 B, 0x247822 to 0x247823 | 6. Allocator tables, task records, reserve table |
| alloc.RL_FLBITS | 0x247824 | 2 | .bss | host | yes: 1 of 2 B, 0x247824 to 0x247825 | 6. Allocator tables, task records, reserve table |
| alloc.RL_SLBITS | 0x247826 | 14 | .bss | host | yes: 6 of 14 B, 0x247826 to 0x24782c | 6. Allocator tables, task records, reserve table |
| alloc.LOW_HINT | 0x247834 | 4 | .bss | host | no | 6. Allocator tables, task records, reserve table |
| alloc.U_BUMP | 0x247838 | 65,536 | .bss | host | yes: 111 of 65,536 B, 0x247df8 to 0x2486fc | 6. Allocator tables, task records, reserve table |
| alloc.DOUBLE_FREES | 0x257838 | 4 | .bss | host | no | 8. Host globals |
| alloc.U_FREE | 0x25783c | 65,536 | .bss | host | yes: 84 of 65,536 B, 0x257dfc to 0x258700 | 6. Allocator tables, task records, reserve table |
| alloc.U_INAV | 0x26783c | 32,768 | .bss | host | yes: 50 of 32,768 B, 0x267b1c to 0x267f9e | 6. Allocator tables, task records, reserve table |
| alloc.U_LIVE | 0x26f83c | 65,536 | .bss | host | yes: 50 of 65,536 B, 0x26fdfc to 0x2706ff | 6. Allocator tables, task records, reserve table |
| alloc.U_ANEXT | 0x27f83c | 65,536 | .bss | host | yes: 36 of 65,536 B, 0x27fe08 to 0x280700 | 6. Allocator tables, task records, reserve table |
| alloc.U_APREV | 0x28f83c | 65,536 | .bss | host | yes: 38 of 65,536 B, 0x28fdfc to 0x290700 | 6. Allocator tables, task records, reserve table |
| alloc.LAST_OWNER | 0x29f83c | 4 | .bss | host | yes: 1 of 4 B, 0x29f83c to 0x29f83d | 6. Allocator tables, task records, reserve table |
| alloc.LAST_SLOT | 0x29f840 | 4 | .bss | host | yes: 1 of 4 B, 0x29f840 to 0x29f841 | 6. Allocator tables, task records, reserve table |
| alloc.RL_HEAD | 0x29f844 | 224 | .bss | host | yes: 30 of 224 B, 0x29f846 to 0x29f89c | 6. Allocator tables, task records, reserve table |
| mem.TRAP_CLEAN | 0x29f924 | 1 | .bss | host | no | 8. Host globals |
| alloc.DEALLOC_MISS | 0x29f928 | 4 | .bss | host | no | 8. Host globals |
| alloc.ROC_BYTES | 0x29f92c | 4 | .bss | host | yes: 4 of 4 B, 0x29f92c to 0x29f930 | 8. Host globals |
| host.COPY | 0x29f930 | 1 | .bss | host | no | 8. Host globals |
| host.TASK_WAITS | 0x29f934 | 4 | .bss | host | yes: 1 of 4 B, 0x29f934 to 0x29f935 | 8. Host globals |
| host.TASK_SAVED_MAX | 0x29f938 | 4 | .bss | host | yes: 3 of 4 B, 0x29f938 to 0x29f93b | 8. Host globals |
| host.TASK_SAVED_PEAK | 0x29f93c | 4 | .bss | host | yes: 3 of 4 B, 0x29f93c to 0x29f93f | 8. Host globals |
| host.TASK_SAVED | 0x29f940 | 4 | .bss | host | yes: 3 of 4 B, 0x29f940 to 0x29f943 | 8. Host globals |
| host.TASK_WAITING | 0x29f944 | 4 | .bss | host | yes: 1 of 4 B, 0x29f944 to 0x29f945 | 8. Host globals |
| host.FILL_TAG | 0x29f948 | 4 | .bss | host | yes: 1 of 4 B, 0x29f948 to 0x29f949 | none (bench only) |
| host.FILLED | 0x29f94c | 4 | .bss | host | yes: 2 of 4 B, 0x29f94c to 0x29f94e | none (bench only) |
| host.FILL | 0x29f950 | 262,144 | .bss | host | yes: 2,750 of 262,144 B, 0x29f951 to 0x2a08ef | none (bench only) |
| host.WAITS | 0x2df950 | 1,024 | .bss | host | yes: 115 of 1,024 B, 0x2df979 to 0x2dfa57 | 8. Host globals |
| host.TASK_TOP | 0x2dfd50 | 4 | .bss | host | no | 8. Host globals |
| host.FAULT_NEXT | 0x2dfd54 | 4 | .bss | host | no | none (bench only) |
| host.WAITS_FREE_HINT | 0x2dfd58 | 4 | .bss | host | yes: 1 of 4 B, 0x2dfd58 to 0x2dfd59 | 8. Host globals |
| roc.RocHostOf(roc_platform_abi.RocHost).env | 0x2dfd5c | 1 | .bss | host | no | 7. Constant data |
| boxy_abi.global | 0x2dfd60 | 4 | .bss | roc | yes: 1 of 4 B, 0x2dfd62 to 0x2dfd63 | NONE |
| main.initialized | 0x2dfd64 | 1 | .bss | roc | yes: 1 of 1 B, 0x2dfd64 to 0x2dfd65 | NONE |
| heap.BrkAllocator.global | 0x2dfd68 | 172 | .bss | roc | yes: 54 of 172 B, 0x2dfd68 to 0x2dfddb | NONE |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 3,014,656 of 3,014,656 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | allocator globals, counters, log; allocator globals, counters; trap flag; host globals |
| Regions with no PLAN 12 row | Roc side statics (.data); Roc side statics (.bss) |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |
| Bench-only regions (not in a production build, PLAN 7a) | bench only: heap_fill, 262,152 B; bench only: fault_next_wait, 4 B |

RESULT: 2 region(s) are not in the table.
