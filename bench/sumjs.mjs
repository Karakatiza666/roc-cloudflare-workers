// Sum of adopted JS blocks (PLAN.md 6e, for 12a): node bench/sumjs.mjs bench/out/alloc_driver.wasm
// Task 7 adopts a small and a large JS block. A change of one byte in either block must
// change the sum of task 7. A change in a JS block that task 8 adopted must not. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(process.argv[2])), {}).exports;
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
run([[1 | (4 << 8), 7, 0, 40], [8, 0, 1, 30], [8, 0, 2, 9000], [8, 0, 3, 30], [6, 7, 1, 0], [6, 7, 2, 0], [6, 8, 3, 0]]);
const sum = (k) => { run([[5, 7, k, 0]]); return x.sum_of(k); };
const s0 = sum(0);
let ok = true;
for (const [id, off, mustChange] of [[1, 20, true], [2, 8000, true], [3, 20, false]]) {
  const m = new Uint8Array(x.memory.buffer);
  const a = x.ptr_of(id) + off;
  m[a] ^= 0x5a;
  const s1 = sum(id);
  m[a] ^= 0x5a;
  const pass = (s1 !== s0) === mustChange && sum(10 + id) === s0;
  if (!pass) ok = false;
  console.log(`JS block ${id} (task ${id === 3 ? 8 : 7}), byte ${off} changed: sum of task 7 ${s1 !== s0 ? 'changed' : 'same'}: ${pass ? 'ok' : 'FAIL'}`);
}
console.log(ok ? 'PASS sumjs' : 'FAIL sumjs');
process.exit(ok ? 0 : 1);
