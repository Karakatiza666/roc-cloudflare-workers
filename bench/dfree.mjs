// Double-free tests on the allocator driver: node bench/dfree.mjs bench/out/alloc_driver.wasm
// (copied from research/alloc/scripts/dfree.mjs, plus case 2). Exit 1 on a failure.
// 1. Alloc, free, free again, then two allocs: the three live blocks must differ.
//    Block 3 stays live, so the page stays with the task between the two frees.
// 2. Task A frees a block, its empty page goes to task B, then A frees the block again:
//    B's block must stay live, and `dealloc_miss` goes up (the owner check at free).
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const inst = () => new WebAssembly.Instance(mod, {}).exports;
const runOn = (x, ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
const A = 1 | (4 << 8); // alloc, alignment 4
let ok = true;
let x = inst();
for (const len of [24, 100, 2000]) {
  runOn(x, [[A, 7, 3, len], [A, 7, 0, len], [2, 7, 0, 0], [2, 7, 0, 0], [A, 7, 1, len], [A, 7, 2, len]]);
  const live = [x.ptr_of(3), x.ptr_of(1), x.ptr_of(2)];
  const pass = new Set(live).size === 3;
  if (!pass) ok = false;
  console.log(`case 1, len ${len}: live blocks after a double free ${live.join(' ')}: ${pass ? 'ok' : 'SAME BLOCK TWICE'}`);
}
console.log(`case 1: double frees caught ${x.double_frees()} (expected 3)`);
if (x.double_frees() !== 3) ok = false;

for (const len of [24, 2000]) {
  x = inst();
  runOn(x, [[A, 7, 10, len], [2, 7, 10, 0], [A, 8, 11, len]]);
  const same = x.ptr_of(11) === x.ptr_of(10);
  const live0 = x.live_bytes(), miss0 = x.dealloc_miss();
  runOn(x, [[2, 7, 10, 0], [A, 8, 12, len]]);
  const pass = same && x.ptr_of(12) !== x.ptr_of(11) && x.live_bytes() > live0 && x.dealloc_miss() === miss0 + 1;
  if (!pass) ok = false;
  console.log(`case 2, len ${len}: page went to B ${same}, B's blocks ${x.ptr_of(11)} ${x.ptr_of(12)}, dealloc_miss ${miss0} -> ${x.dealloc_miss()}: ${pass ? 'ok' : 'FAIL (B block freed by A)'}`);
}
console.log(ok ? 'PASS dfree' : 'FAIL dfree');
process.exit(ok ? 0 : 1);
