// CPU per request: A (instance per request) vs B, B + heap walk, B + walk and Fletcher sum at each wait.
// Waits resolve at once (no I/O), so the time is CPU. node ab.mjs [n=3000]
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './bench/core.js';
const m = new WebAssembly.Module(readFileSync('out/app.wasm'));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const n = Number(process.argv[2] ?? 3000);
let id = 1;
async function run(mode, conc, items, depth = 50) {
  const r = makeRunner(m, mode === 'a' ? 'a' : 'b', io);
  if (mode !== 'a') r.x.set_sum({ b: 0, walk: 2, sum: 1 }[mode]);
  let bad = 0, live = 0, peakA = 0;
  const batch = async () => {
    const ids = Array.from({ length: conc }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
    res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
    if (mode === 'a') peakA = Math.max(peakA, res.reduce((s, x) => s + x.x.memory.buffer.byteLength, 0));
  };
  for (let i = 0; i < 300 / conc + 3; i++) await batch(); // warm up
  const x0 = r.x;
  const b0 = x0?.sum_bytes() ?? 0, w0 = x0?.task_waits() ?? 0;
  const t = performance.now();
  for (let done = 0; done < n; done += conc) await batch();
  const us = ((performance.now() - t) * 1000) / n;
  const waits = (r.x?.task_waits() ?? 0) - w0;
  return { mode, conc, items, usPerReq: +us.toFixed(1), summedKBperWait: waits ? +((r.x.sum_bytes() - b0) / waits / 1024).toFixed(1) : null, memMB: +((mode === 'a' ? peakA : r.x.memory.buffer.byteLength) / 2 ** 20).toFixed(1), bad };
}
const rows = [];
for (const items of [200, 2000]) for (const conc of [1, 16, 64]) for (const mode of ['a', 'b', 'walk', 'sum']) {
  const reps = [];
  for (let k = 0; k < 3; k++) reps.push(await run(mode, conc, items));
  reps.sort((p, q) => p.usPerReq - q.usPerReq);
  rows.push(reps[1]);
}
console.table(rows);
