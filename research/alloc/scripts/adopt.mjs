// Adopt test: JS blocks (js_alloc) adopted by task 7, then task 7 traps clean
// (freeOwner): its adopted blocks must be freed. A block that task 8 adopted stays.
// node adopt.mjs <version>. Exit code 1 on failure.
import { readFileSync } from 'node:fs';
const v = process.argv[2];
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(new URL(`../out/replay_${v}.wasm`, import.meta.url))), {}).exports;
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
// Task 7 makes a block of its own, so it has a record; then three JS blocks (small, small, large).
run([[1 | (4 << 8), 7, 0, 40], [8, 0, 1, 30], [8, 0, 2, 500], [8, 0, 3, 9000], [8, 0, 4, 30]]);
const base = x.live_bytes();
run([[6, 7, 1, 0], [6, 7, 2, 0], [6, 7, 3, 0], [6, 8, 4, 0]]);
run([[9, 7, 0, 0]]);
const after = x.live_bytes();
// Left: the block adopted by task 8 (30 + 8 B in class 48).
const ok = after === 48;
console.log(`${v}: live before the trap ${base} B, after freeOwner(7) ${after} B: ${ok ? 'ok' : 'FAIL (adopted blocks not freed)'}`);
process.exit(ok ? 0 : 1);
