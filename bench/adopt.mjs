// Adopt test on the allocator driver: node bench/adopt.mjs bench/out/alloc_driver.wasm
// (copied from research/alloc/scripts/adopt.mjs). JS blocks (js_alloc) adopted by
// task 7, then task 7 traps clean (freeOwner): its adopted blocks must be freed. A block
// that task 8 adopted stays. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(process.argv[2])), {}).exports;
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
// Task 7 makes a block of its own, so it has a record; then JS blocks (small, small, large, small).
run([[1 | (4 << 8), 7, 0, 40], [8, 0, 1, 30], [8, 0, 2, 500], [8, 0, 3, 9000], [8, 0, 4, 30]]);
const base = x.live_bytes();
run([[6, 7, 1, 0], [6, 7, 2, 0], [6, 7, 3, 0], [6, 8, 4, 0]]);
run([[9, 7, 0, 0]]);
const after = x.live_bytes();
// Left: the block adopted by task 8 (30 + 8 B in class 48).
const ok = after === 48;
console.log(`live before the trap ${base} B, after freeOwner(7) ${after} B: ${ok ? 'ok' : 'FAIL (adopted blocks not freed)'}`);
console.log(ok ? 'PASS adopt' : 'FAIL adopt');
process.exit(ok ? 0 : 1);
