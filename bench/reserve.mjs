// Reserve test on the allocator driver: node bench/reserve.mjs bench/out/alloc_driver.wasm
// (copied from research/alloc/scripts/reserve.mjs). When memory is at its cap, a large
// block must get the empty small pages in the reserve, not fail. 300 small pages are
// filled, then 64 KB blocks fill memory to the cap (128 MB), then the small pages are
// freed (256 go to the reserve) and one 1 MB block is made. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(process.argv[2])), {}).exports;
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
const N = 600; // two 2,000 B blocks per page: 300 pages
run(Array.from({ length: N }, (_, i) => [1 | (4 << 8), 7, i, 2000]));
let id = N + 1, fill = 0;
for (;;) { // a failed alloc traps: memory is full
  try { run([[1 | (4 << 8), 7, id++, 64 << 10]]); fill++; } catch { break; }
}
run(Array.from({ length: N }, (_, i) => [2, 7, i, 0]));
let ok = true;
try { run([[1 | (4 << 8), 7, N, 1 << 20]]); } catch { ok = false; }
console.log(`memory ${x.memory.buffer.byteLength / 2 ** 20} MB, full after ${fill} blocks of 64 KB; a 1 MB block after 300 free pages: ${ok ? 'ok' : 'OUT OF MEMORY'}`);
console.log(ok ? 'PASS reserve' : 'FAIL reserve');
process.exit(ok ? 0 : 1);
