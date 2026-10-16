// CPU cost of the sums (PLAN.md 12a, 12b; a short form of research/alloc/scripts/ab.mjs, "CPU: full app").
// node bench/sumcost.mjs bench/out/app.wasm[,more.wasm] [n=3000] [reps=3]. Env CONC (default 64), ITEMS (default 200,2000),
// MODES (default off,afterAlarm,always), RAW (a file for the runs, as JSON).
// Variant b, waits that resolve at once (so the time is CPU), resumeCheck "off", "afterAlarm" and
// "always", the checks of 12e on (the defaults of `heapCheckEvery` and the idle check). The modes
// run in turn in each rep. Prints the median µs per request of each mode, and the spread.
// 12f: a list of files (comma) runs each file in turn in each rep, so drift hits all alike. A file
// whose host refuses mode "off" (the production host, `app_prod.wasm`) skips that mode.
import { readFileSync, writeFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const files = process.argv[2].split(',');
const modules = files.map((f) => new WebAssembly.Module(readFileSync(f)));
const n = Number(process.argv[3] ?? 3000), reps = Number(process.argv[4] ?? 3);
const list = (env, all) => (process.env[env] ? process.env[env].split(',').map(Number) : all);
const MODES = process.env.MODES ? process.env.MODES.split(',') : ['off', 'afterAlarm', 'always'];
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);

async function run(module, mode, conc, items, depth = 50) {
  let id = 1;
  const r = makeRunner(module, 'b', io, { resumeCheck: mode });
  let bad = 0;
  const batch = async () => {
    const ids = Array.from({ length: conc }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
    res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
  };
  for (let i = 0; i < 300 / conc + 3; i++) await batch(); // warm up
  // The production host has no `task_waits`: the app waits 2 times per request.
  const waits = () => (r.x.task_waits ? r.x.task_waits() : 0);
  const c0 = r.x.sum_checks(), w0 = waits(), h0 = r.stats.heapChecks;
  const t = performance.now();
  for (let done = 0; done < n; done += conc) await batch();
  const us = ((performance.now() - t) * 1000) / n;
  return { us, bad, checksPerWait: (r.x.sum_checks() - c0) / (r.x.task_waits ? waits() - w0 : 2 * n), heapChecks: r.stats.heapChecks - h0, memMB: r.x.memory.buffer.byteLength / 2 ** 20 };
}

const rows = [], raw = [];
for (const items of list('ITEMS', [200, 2000])) {
  for (const conc of list('CONC', [64])) {
    const got = {};
    for (let k = 0; k < reps; k++) {
      for (let f = 0; f < files.length; f++) {
        for (const m of MODES) {
          let x;
          try {
            x = await run(modules[f], m, conc, items);
          } catch (e) {
            if (m === 'off' && /production host/.test(String(e))) continue; // the production host has no mode "off"
            throw e;
          }
          (got[`${f}:${m}`] ??= []).push(x);
          raw.push({ file: files[f], items, conc, mode: m, rep: k, ...x });
        }
      }
    }
    const med = (key) => [...got[key]].sort((p, q) => p.us - q.us)[Math.floor(got[key].length / 2)];
    const base = got['0:off'] ? med('0:off').us : got['0:afterAlarm'] ? med('0:afterAlarm').us : undefined;
    for (let f = 0; f < files.length; f++) {
      for (const m of MODES) {
        const key = `${f}:${m}`;
        if (!got[key]) continue;
        const x = med(key), us = got[key].map((r) => r.us);
        rows.push({
          ...(files.length > 1 ? { file: files[f].replace(/^.*\//, '') } : {}),
          items, conc, mode: m, usPerReq: +x.us.toFixed(1), vsOff: base ? `${(((x.us - base) / base) * 100).toFixed(1)} %` : '-',
          checksPerWait: +x.checksPerWait.toFixed(2), heapChecks: x.heapChecks, memMB: +x.memMB.toFixed(1), bad: got[key].reduce((s, r) => s + r.bad, 0),
          min: Math.round(Math.min(...us)), max: Math.round(Math.max(...us)), memMax: +Math.max(...got[key].map((r) => r.memMB)).toFixed(1),
          runs: got[key].map((r) => Math.round(r.us)).join(' '),
        });
      }
    }
  }
}
console.table(rows);
if (process.env.RAW) writeFileSync(process.env.RAW, JSON.stringify(raw));
