// The short paths of the small blocks (research/alloc v8 in hostlib/alloc.zig): node bench/fastpath.mjs bench/out/alloc_driver.wasm
// 1. A free in a full page takes the slow path: the page goes back to the list of pages with room (global check 0),
//    and the next alloc of the class gets the freed block.
// 2. Home slots: tasks 1 and 129 have the same home slot. Task 129 starts while task 1 is live: task 1 keeps its
//    blocks and its sum, and the two tasks get different pages.
// 3. A realloc of a pointer inside a small block (offset 8): the room is the class minus the offset. A new length
//    that does not fit after the pointer moves the block, and the next block is not changed.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const al = 8 << 8;
let ok = true;
const check = (pass, text) => {
  console.log(`${text}: ${pass ? 'ok' : 'FAIL'}`);
  if (!pass) ok = false;
};
const fresh = () => {
  const x = new WebAssembly.Instance(mod, {}).exports;
  x.set_free_mark((crypto.getRandomValues(new Uint32Array(1))[0] | 1) >>> 0);
  const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
  return { x, run };
};

{
  const { x, run } = fresh();
  // Fill the first page of the class, and one block of the next page.
  let n = 0;
  run([[1 | al, 7, n, 24]]);
  const page = x.ptr_of(0) >> 12;
  while (x.ptr_of(n) >> 12 === page) run([[1 | al, 7, ++n, 24]]);
  const p = x.ptr_of(3);
  run([[2, 7, 3, 0]]);
  const chk = x.check_tables();
  run([[1 | al, 7, n + 1, 24]]);
  check(chk === 0 && x.ptr_of(n + 1) === p, `1. free in a full page of ${n} blocks: global check ${chk}, next alloc at the freed block ${x.ptr_of(n + 1) === p}`);
}

{
  const { x, run } = fresh();
  run([[1 | al, 1, 0, 24]]);
  const a = x.ptr_of(0);
  new Uint8Array(x.memory.buffer, a, 16).fill(0x5a);
  run([[5, 1, 1, 0]]);
  const sum0 = x.sum_of(1);
  run([[1 | al, 129, 1, 24]]);
  new Uint8Array(x.memory.buffer, x.ptr_of(1), 16).fill(0xa5);
  run([[1 | al, 1, 2, 24], [5, 1, 2, 0]]);
  const chk = x.check_tables();
  const bytes = new Uint8Array(x.memory.buffer, a, 16).every((b) => b === 0x5a);
  const pages = new Set([a >> 12, x.ptr_of(1) >> 12]).size === 2 && x.ptr_of(2) >> 12 === a >> 12;
  run([[2, 1, 0, 0], [2, 1, 2, 0], [4, 1, 0, 0], [2, 129, 1, 0], [4, 129, 0, 0]]);
  check(chk === 0 && pages && bytes && x.check_tables() === 0 && x.live_bytes() === 0,
    `2. tasks 1 and 129 (one home slot): global check ${chk}, own pages ${pages}, bytes of task 1 ${bytes ? 'same' : 'changed'}, live at the end ${x.live_bytes()}`);
  // The sum of task 1 after task 129 started: the new block of task 1 is in it, so compare against a sum of the same blocks.
  const { x: y, run: runY } = fresh();
  runY([[1 | al, 1, 0, 24]]);
  new Uint8Array(y.memory.buffer, y.ptr_of(0), 16).fill(0x5a);
  runY([[5, 1, 1, 0], [1 | al, 1, 2, 24], [5, 1, 2, 0]]);
  check(y.sum_of(1) === sum0 && x.sum_of(2) === y.sum_of(2), `2. sum of task 1 with task 129 live: ${x.sum_of(2) === y.sum_of(2) ? 'same' : 'changed'} as with task 1 alone`);
}

{
  const { x, run } = fresh();
  run([[1 | al, 7, 0, 24], [1 | al, 7, 1, 24]]);
  const p = x.ptr_of(0);
  const size = x.ptr_of(1) - p;
  new Uint8Array(x.memory.buffer, x.ptr_of(1), 16).fill(0x77);
  // Realloc at p + 8 to a length that fits in the class but not after the pointer.
  run([[3 | al | (8 << 16), 7, 0, size - 4]]);
  const moved = x.ptr_of(0) !== p;
  new Uint8Array(x.memory.buffer, x.ptr_of(0) + 8, size - 4).fill(0x11);
  const next = new Uint8Array(x.memory.buffer, x.ptr_of(1), 16).every((b) => b === 0x77);
  check(moved && next && x.check_tables() === 0, `3. realloc at offset 8 to ${size - 4} B in a block of ${size} B: moved ${moved}, next block ${next ? 'same' : 'changed'}`);
}

console.log(ok ? 'PASS fastpath' : 'FAIL fastpath');
process.exit(ok ? 0 : 1);
