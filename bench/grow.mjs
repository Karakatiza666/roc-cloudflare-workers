// PLAN.md 4b, 4d step 1 (and the retry with the needed size, 4g follow-up): the allocator asks JS (`js_grow`) before each grow, on the driver
// that is built with the ask (bench/alloc-test.sh: alloc_driver_grow.wasm).
// node bench/grow.mjs bench/out/alloc_driver_grow.wasm. Exit 1 on a failure.
// 1. Each grow is asked first, for max(needed, step) pages, and memory grows only on yes.
// 2. A no: no growth, `js_alloc` gives 0 (the task gets a clean OOM trap in the app).
// 3. A grow step of 1 MB (`set_grow_step`): the grow is 16 pages.
// 4. Step 1 of M7 (reclaim): small pages in the reserve go back to the pool when a grow is
//    denied, and a large block fits in them.
// 5. A step that is larger than the room that is left: when js_grow denies it, the allocator asks once more
//    for the needed pages only. If that is denied too, the allocation fails (and the memory stays).
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const PAGE = 65536;
// `answer`: what js_grow gives. `asked`: the pages of each call.
const make = () => {
  const st = { asked: [], answer: () => 1 };
  const x = new WebAssembly.Instance(mod, { env: { js_grow: (pages) => { st.asked.push(pages); return st.answer(pages) ? 1 : 0; } } }).exports;
  return { x, st, mem: () => x.memory.buffer.byteLength / PAGE };
};
const run = (x, ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
const JS = (id, len) => [8, 0, id, len];
const A = 1 | (4 << 8);

// 1.
{
  const { x, st, mem } = make();
  run(x, [JS(0, 100)]); // the first allocation starts the pool: one step (1 page)
  const m0 = mem();
  const sizes = [30000, 200000, 70000];
  const got = [];
  for (const [i, len] of sizes.entries()) {
    const before = st.asked.length, mb = mem();
    run(x, [JS(i + 1, len)]);
    got.push({ len, asked: st.asked.slice(before), grew: mem() - mb });
  }
  console.log('1.', JSON.stringify({ first: st.asked[0], m0, got }));
  if (st.asked[0] !== 1) fail('1: the first grow is not asked for 1 page (the step):', st.asked[0]);
  for (const g of got) {
    for (const p of g.asked) if (p < 1) fail('1: a grow of 0 pages');
    const total = g.asked.reduce((a, b) => a + b, 0);
    if (g.grew !== total) fail(`1: len ${g.len}: asked ${total} pages, memory grew ${g.grew}`);
  }
  // 200,000 bytes need 49 units (4 KB): more than the free top run, so the ask is for at least 4 pages.
  if (got[1].asked.length === 0 || got[1].asked[0] < 3) fail('1: a request of 200,000 bytes did not ask for its pages', got[1]);
}
// 2.
{
  const { x, st, mem } = make();
  run(x, [JS(0, 100)]);
  const m0 = mem();
  st.answer = () => 0;
  const n0 = st.asked.length;
  run(x, [JS(1, 500000)]);
  console.log('2.', JSON.stringify({ asked: st.asked.length - n0, ptr: x.ptr_of(1), grew: mem() - m0 }));
  if (st.asked.length === n0) fail('2: no ask');
  if (x.ptr_of(1) !== 0) fail('2: js_alloc did not give 0');
  if (mem() !== m0) fail('2: memory grew after a no');
  st.answer = () => 1;
  run(x, [JS(2, 500000)]);
  if (x.ptr_of(2) === 0) fail('2: no block after a yes');
}
// 3.
{
  const { x, st } = make();
  x.set_grow_step(1 << 20);
  run(x, [JS(0, 100)]);
  console.log('3.', JSON.stringify({ asked: st.asked }));
  if (st.asked[0] !== 16) fail('3: step 1 MB: asked', st.asked[0], 'pages, want 16');
}
// 4.
{
  const { x, st, mem } = make();
  // 300 blocks of 2,000 bytes: 2 on each 4 KB page, so 150 pages. All freed: the pages go to the reserve.
  const n = 300;
  run(x, Array.from({ length: n }, (_, i) => [A, 7, i, 2000]));
  run(x, Array.from({ length: n }, (_, i) => [2, 7, i, 0]));
  const m0 = mem();
  st.answer = () => 0;
  const n0 = st.asked.length;
  // 300 KB: 75 units. It does not fit in the free run at the top, so the reserve must join the pool.
  run(x, [JS(1000, 300000)]);
  console.log('4.', JSON.stringify({ denied: st.asked.length - n0, ptr: x.ptr_of(1000), grew: mem() - m0, live: x.live_bytes() }));
  if (st.asked.length === n0) fail('4: no ask: the block fit with no reclaim (the test proves nothing)');
  if (x.ptr_of(1000) === 0) fail('4: the reserve did not go back to the pool: the block does not fit');
  if (mem() !== m0) fail('4: memory grew after a no');
  if (x.check_tables() !== 0) fail('4: the tables are wrong after the reclaim');
}
// 5.
{
  const { x, st, mem } = make();
  x.set_grow_step(1 << 20); // 16 pages
  const ROOM = 3; // pages that the budget has left
  st.answer = (pages) => pages <= ROOM;
  const m0 = mem();
  run(x, [JS(1, 150000)]); // 37 units: 3 pages. The step (16 pages) does not fit, the needed pages do.
  const asked1 = st.asked.slice();
  console.log('5.', JSON.stringify({ asked: asked1, ptr: x.ptr_of(1), grew: mem() - m0 }));
  if (JSON.stringify(asked1) !== '[16,3]') fail('5: asked', asked1, 'want [16, 3]');
  if (x.ptr_of(1) === 0 || mem() - m0 !== 3) fail('5: the grow with the needed size did not pass: ptr', x.ptr_of(1), 'grew', mem() - m0);
  const n1 = st.asked.length, m1 = mem();
  run(x, [JS(2, 400000)]); // 98 units: 7 pages. Denied for the step and for the needed size.
  console.log('5.', JSON.stringify({ asked: st.asked.slice(n1), ptr: x.ptr_of(2), grew: mem() - m1 }));
  if (st.asked.length - n1 !== 2 || x.ptr_of(2) !== 0 || mem() !== m1) fail('5: a need that does not fit must be asked twice, then fail with no growth');
  if (x.check_tables() !== 0) fail('5: the tables are wrong');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
