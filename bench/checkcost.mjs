// Time of the global check (PLAN.md 12d) and the default of `heapCheckEvery` (12e).
// node bench/checkcost.mjs bench/out/app.wasm [n=3000] [reps=3]. Env ITEMS (default 200,2000), CONC (default 64).
// 1. Check time: CONC tasks of ITEMS items wait at their first wait (the heap is full of their
//    pages). `check_heap` runs 200 times; the median time. Also with no task (an empty heap).
// 2. Request time: CONC requests at once, waits that resolve at once (CPU time), no global
//    check. Median of `reps` runs, µs per request.
// 3. N: the smallest round number (1, 2, 5 x 10^k) with check time / (N x request time) <= 0.001.
// 4. Cost with N: the same runs with `heapCheckEvery` N. The time in the checks against the CPU
//    time of the process (`process.cpuUsage`), in %. Must be at most 0.1 %.
import { readFileSync } from 'node:fs';
import { makeRunner, check, HEAP_CHECK_EVERY } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const n = Number(process.argv[3] ?? 3000), reps = Number(process.argv[4] ?? 3);
const list = (env, all) => (process.env[env] ? process.env[env].split(',').map(Number) : all);
const CONC = list('CONC', [64])[0];
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const median = (v) => [...v].sort((p, q) => p - q)[Math.floor(v.length / 2)];
const DEPTH = 50;

// 1. ------------------------------------------------------------------------------------------
function timeCheck(x, k = 200) {
  const t = [];
  for (let i = 0; i < k; i++) {
    const t0 = performance.now();
    const code = x.check_heap();
    t.push(performance.now() - t0);
    if (code !== 0) throw new Error(`check_heap gave ${code}`);
  }
  return median(t);
}
async function checkTime(items) {
  const gates = [];
  const gated = (kind, a, b) => new Promise((res) => gates.push(() => res(io(kind, a, b))));
  const r = makeRunner(module, 'b', gated, { heapCheckEvery: 0, heapCheckWhenIdle: false });
  const x = r.x;
  const idleMs = timeCheck(x);
  const runs = Array.from({ length: CONC }, (_, i) => r.run(`${i + 1} 0 ${DEPTH} ${items}`));
  for (let i = 0; i < 20 && x.task_waiting() < CONC; i++) await new Promise((res) => setTimeout(res, 0));
  if (x.task_waiting() !== CONC) throw new Error(`${x.task_waiting()} tasks wait, want ${CONC}`);
  const row = { items, tasks: CONC, heapMB: +(x.heap_used() / 2 ** 20).toFixed(1), memMB: +(x.memory.buffer.byteLength / 2 ** 20).toFixed(1), checkMs: +timeCheck(x).toFixed(4), emptyCheckMs: +idleMs.toFixed(4) };
  // Open each wait until all tasks end.
  let done = false;
  const all = Promise.all(runs).finally(() => (done = true));
  while (!done) {
    while (gates.length) gates.shift()();
    await new Promise((res) => setTimeout(res, 0));
  }
  for (const res of await all) if (res.body === undefined) throw new Error(`a task trapped: ${res.trap}`);
  return row;
}

// 2. and 4. -----------------------------------------------------------------------------------
async function reqTime(items, every) {
  let id = 1, bad = 0;
  const r = makeRunner(module, 'b', io, { heapCheckEvery: every, heapCheckWhenIdle: false });
  const batch = async () => {
    const ids = Array.from({ length: CONC }, () => String(id++));
    const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${DEPTH} ${items}`)));
    res.forEach((v, i) => { if (!check(ids[i], v.body ?? '', DEPTH)) bad++; });
  };
  for (let i = 0; i < 300 / CONC + 3; i++) await batch(); // warm up
  const c0 = r.stats.heapChecks, ms0 = r.stats.heapCheckMs, cpu0 = process.cpuUsage();
  const t = performance.now();
  for (let done = 0; done < n; done += CONC) await batch();
  const wallMs = performance.now() - t;
  const cpu = process.cpuUsage(cpu0);
  const cpuMs = (cpu.user + cpu.system) / 1000;
  return { us: (wallMs * 1000) / n, cpuMs, checks: r.stats.heapChecks - c0, checkMs: r.stats.heapCheckMs - ms0, bad, fails: r.stats.heapFails };
}

// The smallest round number (1, 2, 5 x 10^k) at or above v.
function round(v) {
  for (let p = 1; ; p *= 10) for (const m of [1, 2, 5]) if (m * p >= v) return m * p;
}

const rows = [];
for (const items of list('ITEMS', [200, 2000])) {
  const c = await checkTime(items);
  const base = [];
  for (let k = 0; k < reps; k++) base.push((await reqTime(items, 0)).us);
  const reqUs = median(base);
  const N = round((c.checkMs * 1000) / (0.001 * reqUs));
  rows.push({ ...c, reqUs: +reqUs.toFixed(1), N });
}
console.table(rows);
const N = Math.max(...rows.map((r) => r.N));
console.log(`heapCheckEvery: N = ${N} (the largest N of the rows). Default in core.js: ${HEAP_CHECK_EVERY}`);

// 4. The cost with the default of core.js, for each row.
const cost = [];
for (const items of list('ITEMS', [200, 2000])) {
  const runs = [];
  for (let k = 0; k < reps; k++) runs.push(await reqTime(items, HEAP_CHECK_EVERY));
  const m = runs.sort((p, q) => p.us - q.us)[Math.floor(reps / 2)];
  cost.push({ items, heapCheckEvery: HEAP_CHECK_EVERY, requests: n, checks: m.checks, checkMs: +m.checkMs.toFixed(3), cpuMs: +m.cpuMs.toFixed(0), costPct: +((m.checkMs / m.cpuMs) * 100).toFixed(4), usPerReq: +m.us.toFixed(1), bad: m.bad, fails: m.fails });
}
console.table(cost);
const worst = Math.max(...cost.map((c) => c.costPct));
const ok = worst <= 0.1 && cost.every((c) => c.bad === 0 && c.fails === 0 && c.checks > 0);
console.log(ok ? 'PASS' : 'FAIL', `cost of the checks at most ${worst} % of the CPU time (limit 0.1 %)`);
process.exit(ok ? 0 : 1);
