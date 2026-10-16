// False-mark test on the allocator driver: node bench/fmark.mjs bench/out/alloc_driver.wasm
// (copied from research/alloc/scripts/fmark.mjs). A live small block whose first two
// words look like a free block (the free mark, then link 0) must still be freed, and its
// slot used again. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(process.argv[2])), {}).exports;
const mark = (crypto.getRandomValues(new Uint32Array(1))[0] | 1) >>> 0;
x.set_free_mark(mark);
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
let ok = true;
for (const len of [24, 100, 2000]) {
  // Block 3 stays live, so the page stays with the task.
  run([[1 | (4 << 8), 7, 3, len], [1 | (4 << 8), 7, 0, len]]);
  const a = x.ptr_of(0);
  new Uint32Array(x.memory.buffer, a, 2).set([mark, 0]);
  run([[2, 7, 0, 0], [1 | (4 << 8), 7, 1, len]]);
  const pass = x.ptr_of(1) === a;
  if (!pass) ok = false;
  console.log(`len ${len}: freed block ${a}, next block ${x.ptr_of(1)}: ${pass ? 'ok' : 'NOT FREED (leak)'}`);
  run([[2, 7, 1, 0], [2, 7, 3, 0]]);
}
console.log(`double frees counted: ${x.double_frees()} (expected 0)`);
if (x.double_frees() !== 0) ok = false;
console.log(ok ? 'PASS fmark' : 'FAIL fmark');
process.exit(ok ? 0 : 1);
