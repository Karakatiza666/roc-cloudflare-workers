// CPU cost of the sums (PLAN.md 12a, 12b; a short form of research/alloc/scripts/ab.mjs, "CPU: full app").
// node bench/sumcost.mjs bench/out/app.wasm [n=3000] [reps=3]. Env CONC (default 64), ITEMS (default 200,2000).
// Variant b, waits that resolve at once (so the time is CPU), resumeCheck "off", "afterAlarm" and
// "always". The modes run in turn in each rep. Prints the median µs per request of each mode.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const n = Number(process.argv[3] ?? 3000), reps = Number(process.argv[4] ?? 3);
const list = (env, all) => (process.env[env] ? process.env[env].split(',').map(Number) : all);
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const MODES = ['off', 'afterAlarm', 'always'];

async function run(mode, conc, items, depth = 50) {
  let id = 1;
  const r = makeRunner(module, 'b', io, { resumeCheck: mode });
  let bad = 0;
  const batch = async () => {
    const ids = Array.from({ length: conc }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
    res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
  };
  for (let i = 0; i < 300 / conc + 3; i++) await batch(); // warm up
  const c0 = r.x.sum_checks(), w0 = r.x.task_waits();
  const t = performance.now();
  for (let done = 0; done < n; done += conc) await batch();
  const us = ((performance.now() - t) * 1000) / n;
  return { us, bad, checksPerWait: (r.x.sum_checks() - c0) / (r.x.task_waits() - w0), memMB: r.x.memory.buffer.byteLength / 2 ** 20 };
}

const rows = [];
for (const items of list('ITEMS', [200, 2000])) {
  for (const conc of list('CONC', [64])) {
    const got = Object.fromEntries(MODES.map((m) => [m, []]));
    for (let k = 0; k < reps; k++) for (const m of MODES) got[m].push(await run(m, conc, items));
    const med = (m) => got[m].sort((p, q) => p.us - q.us)[Math.floor(reps / 2)];
    const base = med('off').us;
    for (const m of MODES) {
      const x = med(m);
      rows.push({ items, conc, mode: m, usPerReq: +x.us.toFixed(1), vsOff: `${(((x.us - base) / base) * 100).toFixed(1)} %`, checksPerWait: +x.checksPerWait.toFixed(2), memMB: +x.memMB.toFixed(1), bad: x.bad, runs: got[m].map((r) => Math.round(r.us)).join(' ') });
    }
  }
}
console.table(rows);
