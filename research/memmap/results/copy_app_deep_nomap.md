# Memory map: wasm/app_deep.wasm

| Item | Value |
|---|---|
| File | wasm/app_deep.wasm, 23,283 B, sha256 d1b3f2b1048d9305 |
| Request mix | app_deep: one request, many, all waiting, many, overflow, no alloc, overflow, alloc, faults, all waiting, faults, idle, bench: heap_fill, bench: heap_fill freed |
| Map check | no map |
| Symbols | no map: coarse regions only; name section: 0 function names, 0 data names |
| Memory at start | 34 pages (2,228,224 B), maximum none; at the end 2,555,904 B |
| Stack | top 0x100000 (the start of __stack_pointer), stack first: 1, canary ok after init: 1 |
| Requests | ok: 77, trap, NOT clean: 1, trap, clean: 2, cancelled (status 5): 3 |
| After the unclean traps | live bytes 0, canary ok 1 (the pages of an unclean task stay: the instance is replaced in production) |
| At the end of the clean phases | live bytes 0, tasks waiting 0, dealloc_miss 0, canary ok 1, log lines 0 |

## Static regions (below the pool)

"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".

| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |
|---|---|---|---|---|---|---|
| stack | 0x000000 | 0x100000 | 1,048,576 | yes: 213,719 of 1,048,576 B, 0x0000e0 to 0x0ffffd; first in "one request" | 4102 | 4. Shared stack |
| data segments (no map: constant and not constant mixed) | 0x100000 | 0x103621 | 13,857 | yes: 454 of 13,857 B, 0x1001e8 to 0x101216; first in "many, all waiting" | 4 | 7. Constant data (the map splits this) |
| bss, free tail of the initial memory (no map) | 0x103621 | 0x220000 | 1,165,791 | yes: 3,904 of 1,165,791 B, 0x103649 to 0x214d95; first in "one request" | 4 | NONE (needs the map) |

## Heap (units of 4 KB, read from the unit tables)

No map: the unit tables are not found, the heap is not classified.
## Constant after init

Ranges that only `init` (or `set_free_mark`, called before it) writes, and that no request changed. Neighbors are joined. 12d sums these after init.

| Range | Size B | What |
|---|---|---|
| Total, static | 0 | |
| Constant foreign units (unchanged after first seen) | 0 | 0 units |

## Written after init (not the stack)

| Region | Written | PLAN 12 row | 12d |
|---|---|---|---|
| data segments (no map: constant and not constant mixed) | yes: 454 of 13,857 B, 0x1001e8 to 0x101216 | 7. Constant data | sum at init, check (12d) |
| bss, free tail of the initial memory (no map) | yes: 3,904 of 1,165,791 B, 0x103649 to 0x214d95 | NONE | NONE |

## Check

| Check | Result |
|---|---|
| Static regions cover the initial memory | 2,228,224 of 2,228,224 B |
| Constant by design but written | none |
| Row 8 regions not written in this mix (writable by design, so not constant) | none |
| Regions with no PLAN 12 row | bss, free tail of the initial memory (no map) |
| Canary and live bytes at the end of the clean phases | canary ok 1, live bytes 0 |

RESULT: 1 region(s) are not in the table.
