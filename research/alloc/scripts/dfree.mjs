// Double-free test: alloc, free, free again, then two allocs: the three live blocks must differ.
// Block 3 stays live, so the page stays with the task between the two frees.
// node dfree.mjs <version>. Exit code 1 on failure.
import { readFileSync } from 'node:fs';
const v = process.argv[2];
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(new URL(`../out/replay_${v}.wasm`, import.meta.url))), {}).exports;
let ok = true;
for (const len of [24, 100, 2000]) {
  const ops = [[1 | (4 << 8), 7, 3, len], [1 | (4 << 8), 7, 0, len], [2, 7, 0, 0], [2, 7, 0, 0], [1 | (4 << 8), 7, 1, len], [1 | (4 << 8), 7, 2, len]];
  new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat());
  x.run(ops.length);
  const live = [x.ptr_of(3), x.ptr_of(1), x.ptr_of(2)];
  const pass = new Set(live).size === 3;
  if (!pass) ok = false;
  console.log(`${v} len ${len}: live blocks after a double free ${live.join(' ')}: ${pass ? 'ok' : 'SAME BLOCK TWICE'}`);
}
console.log(`${v} double frees caught: ${x.double_frees?.() ?? 'n/a'}`);
process.exit(ok ? 0 : 1);
