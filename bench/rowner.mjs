// Owner check at realloc (PLAN.md 6e open point, settled in 12b): node bench/rowner.mjs bench/out/alloc_driver.wasm
// Task 8 reallocs a block of task 7 (a stale pointer). Expect: a clean trap, `dealloc_miss` + 1,
// and the block of task 7 is not changed (its bytes, its live bytes, the sum of task 7).
// 1. A small block that the realloc must move (24 B to 5,000 B): without the check, task 7's block is freed.
// 2. A large block that the realloc shrinks in place (9,000 B to 100 B): without the check, its requested end changes.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const al = 8 << 8;
let ok = true;
for (const [name, len, newLen] of [['small, move', 24, 5000], ['large, shrink in place', 9000, 100]]) {
  const x = new WebAssembly.Instance(mod, {}).exports;
  x.set_free_mark((crypto.getRandomValues(new Uint32Array(1))[0] | 1) >>> 0);
  const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
  run([[1 | al, 7, 0, len]]);
  const p = x.ptr_of(0);
  new Uint8Array(x.memory.buffer, p, 16).set([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
  run([[5, 7, 1, 0]]);
  const live0 = x.live_bytes(), miss0 = x.dealloc_miss(), sum0 = x.sum_of(1);
  x.clear_trap_clean();
  let got;
  try { run([[3 | al, 8, 0, newLen]]); got = 'returns'; } catch (e) { got = e instanceof WebAssembly.RuntimeError ? 'traps' : String(e); }
  const clean = x.trap_clean();
  run([[5, 7, 2, 0]]);
  const bytes = [...new Uint8Array(x.memory.buffer, p, 16)].join() === '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16';
  const pass = got === 'traps' && clean === 1 && x.dealloc_miss() === miss0 + 1 && x.live_bytes() === live0 && x.sum_of(2) === sum0 && bytes;
  if (!pass) ok = false;
  console.log(`${name}: ${got}, clean ${clean}, dealloc_miss ${miss0} -> ${x.dealloc_miss()}, live ${live0} -> ${x.live_bytes()}, sum of task 7 ${x.sum_of(2) === sum0 ? 'same' : 'changed'}, bytes ${bytes ? 'same' : 'changed'}: ${pass ? 'ok' : 'FAIL'}`);
}
console.log(ok ? 'PASS rowner' : 'FAIL rowner');
process.exit(ok ? 0 : 1);
