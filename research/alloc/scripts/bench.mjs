// CPU per request and memory, sum modes 0 and 1. node bench.mjs [n=3000] [versions=v0 v3 v5]
import { readFileSync } from 'node:fs';
import { makeRunner, check } from '../harness/bench/core.js';
const wasm = (name) => readFileSync(new URL(`../out/${name}.wasm`, import.meta.url));
const vers = process.argv.length > 3 ? process.argv.slice(3) : ['v0', 'v3', 'v5'];
const mods = Object.fromEntries(vers.map((k) => [k, new WebAssembly.Module(wasm(`app_${k}`))]));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const n = Number(process.argv[2] ?? 3000);
const cases = vers.flatMap((v) => [[v, v, 0, 0], [`${v}, sum 1`, v, 1, 0]]);
let id = 1;
async function run([name, mod, sum, grower], conc, items, depth = 50) {
  const r = makeRunner(mods[mod], 'b', io);
  r.x.set_sum(sum);
  
  let bad = 0;
  const batch = async () => {
    const ids = Array.from({ length: conc }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
    res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
  };
  for (let i = 0; i < 300 / conc + 3; i++) await batch();
  const w0 = r.x.task_waits(), b0 = r.x.sum_bytes();
  const t = performance.now();
  for (let done = 0; done < n; done += conc) await batch();
  const us = ((performance.now() - t) * 1000) / n;
  const waits = r.x.task_waits() - w0;
  return { case: name, conc, items, usPerReq: +us.toFixed(1), sumKBperWait: waits && sum ? +((r.x.sum_bytes() - b0) / waits / 1024).toFixed(1) : '', memMB: +(r.x.memory.buffer.byteLength / 2 ** 20).toFixed(1), bad };
}
const rows = [];
for (const items of [200, 2000]) for (const conc of [16, 64]) for (const c of cases) {
  const reps = [];
  for (let k = 0; k < 3; k++) reps.push(await run(c, conc, items));
  reps.sort((p, q) => p.usPerReq - q.usPerReq);
  rows.push(reps[1]);
}
console.table(rows);
