// Cost of owner tags: node bench/owner.mjs <app.wasm, tags on> <app.wasm, tags off>
// Build both with track_live=false (see README). Prints JSON lines.
// 1. alloc + free pair, by size.  2. Heap walk after a trap, by live span count.
// 3. Whole request (shared instance, copy on), waits that resolve at once.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';

const mods = { on: new WebAssembly.Module(readFileSync(process.argv[2])), off: new WebAssembly.Module(readFileSync(process.argv[3])) };
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const inst = (m) => makeRunner(m, io).x;
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
const time = (f) => { const t = performance.now(); f(); return performance.now() - t; };

// 1. ns per alloc + free pair. 64 live at a time.
for (const size of [24, 200, 3000, 20000]) {
  const out = {};
  for (const k of ['on', 'off']) {
    const x = inst(mods[k]);
    const n = size > 4096 ? 2000 : 20000;
    x.alloc_bench(200, 64, size);
    out[k] = +med(Array.from({ length: 7 }, () => (time(() => x.alloc_bench(n, 64, size)) * 1e6) / (n * 64))).toFixed(2);
  }
  console.log(JSON.stringify({ test: 'alloc+free ns', size, ...out }));
}

// 2. One heap walk (freeOwner for a task with no spans) over `count` live spans.
{
  const x = inst(mods.on);
  for (const [count, size] of [[1000, 24], [10000, 24], [65536, 24], [10000, 1000], [65536, 200]]) {
    x.heap_fill(count, size, 7);
    const us = med(Array.from({ length: 9 }, () => time(() => x.walk_bench(123456)) * 1000));
    console.log(JSON.stringify({ test: 'walk us', liveSpans: count, size, heapMB: +(x.heap_used() / 1048576).toFixed(1), us: +us.toFixed(1), nsPerSpan: +((us * 1000) / count).toFixed(2) }));
  }
  x.heap_fill(0, 0, 0);
}

// 3. us per request, one at a time, depth 30, 200 JSON items (about 300 KB of heap work).
{
  let id = 1;
  const runner = { on: makeRunner(mods.on, io), off: makeRunner(mods.off, io) };
  const go = async (r, n) => { let bad = 0; for (let i = 0; i < n; i++) { const k = String(id++); const v = await r.run(`${k} 0 30 200`); if (!check(k, v.body ?? '', 30)) bad++; } return bad; };
  const t = { on: [], off: [] };
  let bad = 0;
  for (const k of ['on', 'off']) bad += await go(runner[k], 300);
  for (let rep = 0; rep < 7; rep++) for (const k of rep % 2 ? ['on', 'off'] : ['off', 'on']) {
    const s = performance.now();
    bad += await go(runner[k], 500);
    t[k].push(((performance.now() - s) * 1000) / 500);
  }
  console.log(JSON.stringify({ test: 'request us', on: +med(t.on).toFixed(1), off: +med(t.off).toFixed(1), onAll: t.on.map((v) => +v.toFixed(1)), offAll: t.off.map((v) => +v.toFixed(1)), bad }));
}
