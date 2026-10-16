// PLAN.md 4h (H3 counters, the leak counter) and 4j (H2 idle reset) on the allocator driver.
// node bench/counters.mjs bench/out/alloc_driver.wasm bench/out/alloc_driver_grow.wasm
// A manual walk of the unit tables (the driver gives their addresses) gives the numbers that the
// counters must show. Exit 1 on a failure.
// 4h-1: heap bytes (`heap_bytes`, `heap_used`) and `live_bytes` match the walk, after random allocs and frees
//       of mixed sizes. `live_peak` is the largest `live_bytes` seen after any single operation.
// 4h-2: a denied grow gives the page reserve back (pressure step 1): `reclaim_walks` is 1 and
//       `reclaim_bytes` is the reserve that the walk counted before.
// 4h-3: the leak counter: the bytes that `taskDone` frees at the end of a task are the live bytes that the
//       walk saw. A task that freed all its blocks: 0. `taskEnd` (a trap) does not count.
// 4j-1: with no live block, `idle_reset` gives back the page reserve and joins the free runs: only the
//       foreign units stay (`heap_used` is 0), each region is one free run, the tables pass `check_tables`, and
//       later blocks do not overlap.
// 4j-2: a live host block, then a live JS block: no reset, the tables and the block are as they were.
// 4j-3: a live count that is too low (`break_table` 19) does not make a reset over a live block.
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const modGrow = new WebAssembly.Module(readFileSync(process.argv[3]));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const CH = 4096;
const CLASSES = [16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048];
const A = 1 | (4 << 8);
const FREE = (owner, id) => [2, owner, id, 0];
const ALLOC = (owner, id, len) => [A, owner, id, len];
const JS = (id, len) => [8, 0, id, len];
const inst = () => new WebAssembly.Instance(mod, {}).exports;
const run = (x, ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
// A seeded generator, so a failure repeats.
let seed = 12345;
const rnd = (n) => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };

// The manual walk: each unit of the pool by its table entries.
function walk(x) {
  const lo = x.pool_lo(), hi = x.pool_hi(), buf = x.memory.buffer;
  const kind = new Uint8Array(buf, x.table_kind(), 32768), live = new Uint16Array(buf, x.table_live(), 32768);
  const cls = new Uint8Array(buf, x.table_class(), 32768), units = new Uint16Array(buf, x.table_units(), 32768);
  const bits = new BigUint64Array(buf, x.table_free_bits(), 512);
  const free = (u) => ((bits[u >> 6] >> BigInt(u & 63)) & 1n) === 1n;
  const w = { lo, hi, free: 0, runs: 0, maxRun: 0, foreign: 0, reserve: 0, regions: 0, liveBytes: 0, kind: kind.slice(lo, hi), bits: bits.slice() };
  let run_ = 0, inRegion = false;
  for (let u = lo; u < hi; u++) {
    if (free(u)) { w.free++; run_++; if (run_ > w.maxRun) w.maxRun = run_; if (run_ === 1) w.runs++; } else run_ = 0;
    if (kind[u] === 4) { w.foreign++; inRegion = false; } else if (!inRegion) { w.regions++; inRegion = true; }
    if (!free(u) && kind[u] === 0) w.reserve++;
    if (kind[u] === 1) w.liveBytes += live[u] * CLASSES[cls[u]];
    if (kind[u] === 2) w.liveBytes += units[u] * CH;
  }
  w.used = w.hi - w.lo - w.free;
  return w;
}
const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
function matches(tag, x, w) {
  if (x.heap_bytes() !== (w.hi - w.lo) * CH) fail(`${tag}: heap_bytes ${x.heap_bytes()}, walk ${(w.hi - w.lo) * CH}`);
  // heap_used counts the units in use, not the foreign ones.
  if (x.heap_used() !== (w.used - w.foreign) * CH) fail(`${tag}: heap_used ${x.heap_used()}, walk ${(w.used - w.foreign) * CH}`);
  if (x.live_bytes() !== w.liveBytes) fail(`${tag}: live_bytes ${x.live_bytes()}, walk ${w.liveBytes}`);
}
const SIZES = [16, 24, 40, 100, 300, 700, 2000, 3000, 9000, 50000, 200000];

// 4h-1 ----------------------------------------------------------------------------------------
{
  const x = inst();
  const live = new Map(); // id -> owner
  let peak = 0, next = 0, checks = 0;
  for (let step = 0; step < 3000; step++) {
    if (live.size === 0 || rnd(10) < 6) {
      const owner = 1 + rnd(6);
      run(x, [ALLOC(owner, next, SIZES[rnd(SIZES.length)])]);
      live.set(next++, owner);
    } else {
      const ids = [...live.keys()], id = ids[rnd(ids.length)];
      run(x, [FREE(live.get(id), id)]);
      live.delete(id);
    }
    peak = Math.max(peak, x.live_bytes());
    if (step % 250 === 249) { matches(`4h-1 step ${step}`, x, walk(x)); checks++; }
  }
  for (let o = 1; o <= 6; o++) run(x, [[4, o, 0, 0]]);
  matches('4h-1 end', x, walk(x));
  console.log('4h-1', JSON.stringify({ heapBytes: x.heap_bytes(), heapUsed: x.heap_used(), livePeak: x.live_peak(), peakSeen: peak, live: x.live_bytes(), walks: checks + 1 }));
  if (x.live_peak() !== peak) fail(`4h-1: live_peak ${x.live_peak()}, the largest live_bytes seen ${peak}`);
  if (peak === 0 || x.live_bytes() !== 0) fail('4h-1: no peak, or live bytes not 0 at the end');
  // A realloc that grows in place and one that moves: the live bytes still match the walk.
  run(x, [ALLOC(1, 0, 5000), [3 | (4 << 8), 1, 0, 9000], ALLOC(1, 1, 20), [3 | (4 << 8), 1, 1, 2000]]);
  matches('4h-1 realloc', x, walk(x));
}

// 4h-2 ----------------------------------------------------------------------------------------
{
  const answer = { yes: true };
  const x = new WebAssembly.Instance(modGrow, { env: { js_grow: () => (answer.yes ? 1 : 0) } }).exports;
  // 300 blocks of 2,000 bytes: 2 on each page, 150 pages. All freed: they go to the reserve.
  run(x, Array.from({ length: 300 }, (_, i) => ALLOC(7, i, 2000)));
  run(x, Array.from({ length: 300 }, (_, i) => FREE(7, i)));
  const w0 = walk(x);
  const w = { walks: x.reclaim_walks(), bytes: x.reclaim_bytes() };
  answer.yes = false;
  run(x, [JS(1000, 300000)]); // 75 units: they do not fit, so the reserve must join the pool
  const w1 = walk(x);
  console.log('4h-2', JSON.stringify({ reserveBefore: w0.reserve, reserveAfter: w1.reserve, before: w, after: { walks: x.reclaim_walks(), bytes: x.reclaim_bytes() }, ptr: x.ptr_of(1000) }));
  if (w0.reserve !== 150) fail(`4h-2: the walk counts ${w0.reserve} reserve pages, want 150 (the test proves nothing)`);
  if (w.walks !== 0 || w.bytes !== 0) fail('4h-2: reclaim counters are not 0 before the denied grow');
  if (x.ptr_of(1000) === 0 || w1.reserve !== 0) fail('4h-2: the reserve did not give its pages back');
  if (x.reclaim_walks() !== 1) fail(`4h-2: reclaim_walks ${x.reclaim_walks()}, want 1`);
  if (x.reclaim_bytes() !== w0.reserve * CH) fail(`4h-2: reclaim_bytes ${x.reclaim_bytes()}, the walk gives ${w0.reserve * CH}`);
}

// 4h-3 ----------------------------------------------------------------------------------------
{
  const x = inst();
  // Task 9 frees one block and leaks the rest: 24 B (class 32), 3,000 B (1 unit).
  run(x, [ALLOC(9, 0, 24), ALLOC(9, 1, 100), ALLOC(9, 2, 3000), FREE(9, 1)]);
  const w = walk(x);
  const l0 = x.leaked_at_end();
  run(x, [[14, 9, 0, 0]]);
  const leak = x.leaked_at_end() - l0;
  // A task that freed all its blocks.
  run(x, [ALLOC(10, 3, 500), ALLOC(10, 4, 70000), FREE(10, 3), FREE(10, 4), [14, 10, 0, 0]]);
  const clean = x.leaked_at_end() - l0 - leak;
  // `taskEnd` (a task that trapped and was freed): no leak count.
  run(x, [ALLOC(11, 5, 500), [4, 11, 0, 0]]);
  console.log('4h-3', JSON.stringify({ walkLive: w.liveBytes, leak, clean, afterTrapPath: x.leaked_at_end() - l0 - leak - clean, live: x.live_bytes() }));
  if (w.liveBytes !== 32 + 4096 || leak !== w.liveBytes) fail(`4h-3: leak ${leak}, the walk saw ${w.liveBytes} live bytes (want 4128)`);
  if (clean !== 0) fail(`4h-3: a task with no leak counted ${clean}`);
  if (x.leaked_at_end() !== l0 + leak) fail('4h-3: taskEnd (a trap) counted as a leak');
  if (x.live_bytes() !== 0) fail('4h-3: live bytes are not 0 at the end');
}

// 4j -------------------------------------------------------------------------------------------
// A heap with foreign units, a full page reserve and fragmented free runs, and no live block. `keep`
// ops run first and stay live. Returns the instance. Each block that stays live gets a pattern.
function heap(keep = []) {
  const x = inst();
  run(x, [JS(60000, 100), FREE(0, 60000)]); // starts the pool
  x.memory.grow(2); // two pages that other code took: foreign units at the next grow of the pool
  run(x, [ALLOC(1, 0, 300000), FREE(1, 0)]); // the grow finds the new pages
  const ids = [];
  for (let i = 1; i <= 1500; i++) { run(x, [ALLOC(1 + (i % 8), i, SIZES[rnd(SIZES.length)])]); ids.push(i); }
  for (const i of ids) if (rnd(2) === 0) run(x, [FREE(1 + (i % 8), i)]);
  for (let o = 1; o <= 8; o++) run(x, [[4, o, 0, 0]]); // all tasks end: the pages go back
  run(x, keep);
  return x;
}
const fill = (x, id, len, v) => new Uint8Array(x.memory.buffer, x.ptr_of(id), len).fill(v);
const intact = (x, id, len, v) => new Uint8Array(x.memory.buffer, x.ptr_of(id), len).every((b) => b === v);

{
  const x = heap();
  const w0 = walk(x);
  const mem0 = x.memory.buffer.byteLength;
  const r = x.idle_reset();
  const w1 = walk(x);
  console.log('4j-1', JSON.stringify({ reset: r, foreign: [w0.foreign, w1.foreign], reserve: [w0.reserve, w1.reserve], usedUnits: [w0.used, w1.used], runs: [w0.runs, w1.runs], regions: w1.regions, maxRun: [w0.maxRun, w1.maxRun], resets: x.idle_resets(), bytes: x.idle_reset_bytes() }));
  if (w0.foreign === 0 || w0.reserve === 0 || w0.runs < 2) fail('4j-1: the heap has no foreign units, no reserve or no fragmentation: the test proves nothing', w0.foreign, w0.reserve, w0.runs);
  if (x.live_bytes() !== 0) fail('4j-1: live bytes are not 0 before the reset');
  if (r !== 1) fail('4j-1: idle_reset did not reset');
  if (w1.foreign !== w0.foreign || w1.used !== w1.foreign) fail(`4j-1: used units ${w1.used}, foreign ${w1.foreign} (want equal, and as before: ${w0.foreign})`);
  if (w1.reserve !== 0) fail(`4j-1: ${w1.reserve} reserve pages are left`);
  if (w1.runs !== w1.regions) fail(`4j-1: ${w1.runs} free runs, ${w1.regions} regions`);
  if (x.heap_used() !== 0) fail(`4j-1: heap_used ${x.heap_used()} after the reset, want 0 (foreign units are not counted)`);
  if (x.heap_bytes() !== (w0.hi - w0.lo) * CH) fail('4j-1: the pool size changed');
  if (x.idle_resets() !== 1 || x.idle_reset_bytes() !== (w0.used - w0.foreign) * CH) fail('4j-1: counters of the reset', x.idle_resets(), x.idle_reset_bytes());
  if (x.check_tables() !== 0) fail('4j-1: check_tables fails after the reset:', x.check_tables());
  // The largest region fits one block at once, with no grow of memory.
  run(x, [ALLOC(1, 5000, w1.maxRun * CH)]);
  if (x.ptr_of(5000) === 0 || x.memory.buffer.byteLength !== mem0) fail('4j-1: the largest free run does not hold a block of its size');
  run(x, [FREE(1, 5000)]);
  // Later blocks do not overlap: each one gets its own pattern.
  const live = [];
  for (let i = 0; i < 800; i++) {
    const len = SIZES[rnd(SIZES.length)], id = 6000 + i;
    run(x, [ALLOC(1 + (i % 5), id, len)]);
    fill(x, id, len, 1 + (i % 250));
    live.push([id, len, 1 + (i % 250)]);
  }
  const bad = live.filter(([id, len, v]) => !intact(x, id, len, v)).length;
  if (bad !== 0) fail(`4j-1: ${bad} blocks overlap after the reset`);
  if (x.check_tables() !== 0) fail('4j-1: check_tables fails after new blocks');
  for (let o = 1; o <= 5; o++) run(x, [[4, o, 0, 0]]);
  if (x.live_bytes() !== 0 || x.check_tables() !== 0) fail('4j-1: the heap is not sound at the end');
}

// A block that stays live: a host block (owner 0), then a JS block. No reset, and no damage.
for (const [name, keep] of [['host block', [ALLOC(0, 9000, 100)]], ['JS block', [JS(9000, 100)]]]) {
  const x = heap(keep);
  fill(x, 9000, 100, 77);
  const w0 = walk(x);
  const r = x.idle_reset();
  const w1 = walk(x);
  const unchanged = same(w0.kind, w1.kind) && same(w0.bits, w1.bits) && w0.used === w1.used && w0.runs === w1.runs && w0.reserve === w1.reserve;
  console.log('4j-2', JSON.stringify({ name, reset: r, resets: x.idle_resets(), unchanged, live: x.live_bytes(), used: [w0.used, w1.used] }));
  if (w0.liveBytes === 0 || x.live_bytes() === 0) fail(`4j-2 ${name}: no live block: the test proves nothing`);
  if (r !== 0 || x.idle_resets() !== 0) fail(`4j-2 ${name}: idle_reset reset with a live block`);
  if (!unchanged) fail(`4j-2 ${name}: the tables changed`);
  if (!intact(x, 9000, 100, 77) || x.check_tables() !== 0) fail(`4j-2 ${name}: the block or the tables are damaged`);
  // Many new blocks: none takes the live block.
  const live = [];
  for (let i = 0; i < 1500; i++) { const len = SIZES[rnd(SIZES.length - 2)], id = 6000 + i; run(x, [ALLOC(1 + (i % 5), id, len)]); fill(x, id, len, 1 + (i % 250)); live.push([id, len, 1 + (i % 250)]); }
  if (!intact(x, 9000, 100, 77) || live.some(([id, len, v]) => !intact(x, id, len, v))) fail(`4j-2 ${name}: blocks overlap`);
  for (let o = 1; o <= 5; o++) run(x, [[4, o, 0, 0]]);
  // The block goes: the next reset is done.
  run(x, [FREE(0, 9000)]);
  if (x.idle_reset() !== 1 || x.check_tables() !== 0) fail(`4j-2 ${name}: no reset after the block was freed`);
}

// A count that is too low must not reset over a live block.
{
  const x = heap([ALLOC(0, 9000, 100)]);
  fill(x, 9000, 100, 77);
  run(x, [[13, 0, 19, 0]]); // break_table(19): live_bytes = 0
  const w0 = walk(x);
  const r = x.idle_reset();
  const w1 = walk(x);
  console.log('4j-3', JSON.stringify({ liveCount: x.live_bytes(), walkLive: w0.liveBytes, reset: r, unchanged: same(w0.kind, w1.kind) && same(w0.bits, w1.bits) }));
  if (x.live_bytes() !== 0 || w0.liveBytes === 0) fail('4j-3: the count is not too low: the test proves nothing');
  if (r !== 0) fail('4j-3: reset over a live block');
  const live = [];
  for (let i = 0; i < 1000; i++) { const len = SIZES[rnd(SIZES.length - 2)], id = 6000 + i; run(x, [ALLOC(1 + (i % 5), id, len)]); fill(x, id, len, 1 + (i % 250)); live.push([id, len, 1 + (i % 250)]); }
  if (!intact(x, 9000, 100, 77) || live.some(([id, len, v]) => !intact(x, id, len, v))) fail('4j-3: the live block was damaged');
}
console.log(failed ? 'FAIL counters' : 'PASS counters');
process.exit(failed ? 1 : 0);
