// PLAN.md 11c: bench/8g/run-edge.mjs for the edge run (edge/deploy-8g.sh, the Free plan). The changes: `/__clock` is
// asked once and its answer is kept as text (on the edge its busy loop goes over the CPU limit: `error code: 1102`), and
// a case whose request fails (the CPU limit) is a row with `error`, not the end of the run.
// PLAN.md step 8g on the Cloudflare edge (11c): the Worker of `deploy-edge.sh`, timed from this machine.
//   EDGE_URL=https://talon-bench-8g.<account>.workers.dev node bench/8g/run-edge.mjs > .cache/results/8g/edge-1.txt
//   env: SECTIONS=cross,d1,d1real,parse,sha  ROUNDS=7  TARGET_MS=1000  (run it 3 times, then `node bench/8g/summarize.mjs` on the files)
// On the edge the clocks move only at I/O (`/__clock` shows it), so the Worker cannot time itself: the client clock times a
// request with n = N and a request with n = 0, and the difference is divided by N. The network path (the round trip, 20 to
// 100 ms with a jitter of some ms) cancels in the difference, and N is large (a request of about one second), so the jitter is
// below 1 %. For the CPU time of the Worker, run `wrangler tail talon-bench-8g --format json` in a second shell: each event
// has `cpuTime` and `wallTime` (whole ms) of one request: the requests of N are the ones with `?n=<N>` in their URL.
import os from 'node:os';
import { makeMeasure, crossCases, d1Cases, parseCases, shaCases, sanity, table, fmt } from '../bench/8g/lib.mjs';

const base = process.env.EDGE_URL?.replace(/\/$/, '');
if (!base) throw new Error('EDGE_URL=https://talon-bench-8g.<account>.workers.dev is needed');
const sections = (process.env.SECTIONS ?? 'cross,d1,d1real,parse,sha').split(',');
const get = (url) => fetch(`${base}${url}`);
const m = makeMeasure(get, { rounds: Number(process.env.ROUNDS ?? 7), targetMs: Number(process.env.TARGET_MS ?? 1000) });
const text = async (url) => (await get(url)).text();
const info = { runtime: 'Cloudflare edge', url: base, cpu: `client ${os.cpus()[0].model}`, load: os.loadavg().map((v) => Math.round(v * 100) / 100), date: new Date().toISOString(), resumeCheck: process.env.RESUME ?? 'see deploy' };
console.log(JSON.stringify({ info }));
if (process.env.CLOCK !== '0') {
  console.log(JSON.stringify({ clock: (await text('/__clock')).slice(0, 200) }));
  // The busy loop of /__clock ends the isolate (1102): the requests of the next seconds can fail too.
  await new Promise((r) => setTimeout(r, 5000));
}
const rows = await text('/__setup?rows=200');
if (rows !== '200') throw new Error(`setup: ${rows}`);
const fails = await sanity(m);
if (fails.length) {
  console.log(JSON.stringify({ sanity: 'FAIL', fails }));
  process.exit(1);
}
console.log(JSON.stringify({ sanity: 'ok' }));
const all = { cross: crossCases(), d1: d1Cases(true), d1real: d1Cases(false), parse: parseCases(), sha: shaCases() };
const results = {};
for (const g of ['cross', 'd1', 'd1real', 'parse', 'sha']) {
  if (!sections.includes(g)) continue;
  results[g] = [];
  for (const c of all[g]) {
    let r;
    try {
      r = await m.measure(c.path, g === 'd1real' ? { rounds: 11, targetMs: Number(process.env.D1_TARGET_MS ?? 3000) } : {});
    } catch (e) {
      console.log(JSON.stringify({ group: g, name: c.name, error: String(e.message).slice(0, 200) }));
      continue;
    }
    results[g].push({ ...c, ...r });
    console.log(JSON.stringify({ group: g, name: c.name, N: r.N, us: r.us, min: r.min, max: r.max }));
  }
}
console.log(JSON.stringify({ load_after: os.loadavg() }));
for (const g of Object.keys(results)) {
  console.log(`\n${g} (us per operation: median, min to max of the rounds)\n`);
  console.log(table(results[g], [['case', (r) => r.name], ['N', (r) => r.N], ['us', fmt]]));
}
process.exit(0);
