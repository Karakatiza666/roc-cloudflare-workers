// Variant A (a new instance per request: many instances per isolate) against
// variant B (one shared instance) with sums off, at each wait (mode 1) and also
// at each resume (mode 2). Waits resolve at once, so the time is CPU.
// A memory: the total of the instances of one batch (all live at once).
// node ab.mjs [n=3000] [versions=v0 v7]. Env CONC, ITEMS: run only these cases (e.g. CONC=16 ITEMS=2000).
import { readFileSync } from 'node:fs';
import { makeRunner, check } from '../harness/bench/core.js';
const wasm = (name) => readFileSync(new URL(`../out/${name}.wasm`, import.meta.url));
const vers = process.argv.length > 3 ? process.argv.slice(3) : ['v0', 'v7'];
const mods = Object.fromEntries(vers.map((k) => [k, new WebAssembly.Module(wasm(`app_${k}`))]));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const n = Number(process.argv[2] ?? 3000);
let id = 1;
async function run(v, mode, conc, items, depth = 50) {
  id = 1; // each run gets the same request ids, so memory compares across versions
  const r = makeRunner(mods[v], mode === 'A' ? 'a' : 'b', io);
  if (mode !== 'A') r.x.set_sum({ B: 0, 'B sum 1': 1, 'B sum 2': 2 }[mode]);
  let bad = 0, peakA = 0;
  const batch = async () => {
    const ids = Array.from({ length: conc }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
    res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
    if (mode === 'A') peakA = Math.max(peakA, res.reduce((s, x) => s + x.x.memory.buffer.byteLength, 0));
  };
  for (let i = 0; i < 300 / conc + 3; i++) await batch(); // warm up
  const t = performance.now();
  for (let done = 0; done < n; done += conc) await batch();
  const us = ((performance.now() - t) * 1000) / n;
  const mem = mode === 'A' ? peakA : r.x.memory.buffer.byteLength;
  return { version: v, mode, conc, items, usPerReq: +us.toFixed(1), memMB: +(mem / 2 ** 20).toFixed(1), bad };
}
const rows = [];
const only = (env, all) => (process.env[env] ? process.env[env].split(',').map(Number) : all);
for (const items of only('ITEMS', [200, 2000])) for (const conc of only('CONC', [1, 16, 64])) for (const v of vers) for (const mode of ['A', 'B', 'B sum 1', 'B sum 2']) {
  const reps = [];
  for (let k = 0; k < 3; k++) reps.push(await run(v, mode, conc, items));
  reps.sort((p, q) => p.usPerReq - q.usPerReq);
  rows.push(reps[1]);
}
console.table(rows);
