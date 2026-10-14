// V4: how often does a retire happen while an older instance still drains?
// node v4.mjs <rate> <meanLatencyMs> [n=20000] [conc=64]
import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const [rate, lat, n = 20000, conc = 64] = process.argv.slice(2).map(Number);
const m = new WebAssembly.Module(readFileSync('out/app_v.wasm'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async () => { await sleep(-Math.log(1 - Math.random()) * lat); return 'x'; };
const r = makeRunner(m, 'b', io, { noFallback: true });
const inflight = new Map();
let i = 0, retires = 0, retireWhileDraining = 0, maxLive = 1, bad = 0;
const drainStart = new Map(), drains = [];
const t0 = performance.now();
let cur = r.x;
const unclean_n = { n: 0 };
async function worker() {
  while (i < n) {
    i++;
    const unclean = Math.random() < rate;
    if (unclean) unclean_n.n++;
    const x = r.x;
    inflight.set(x, (inflight.get(x) ?? 0) + 1);
    const res = await r.run(unclean ? '99 0' : '2 50');
    if (!unclean && res.body === undefined) bad++;
    inflight.set(x, inflight.get(x) - 1);
    if (r.x !== cur) {
      // A retire: `cur` starts to drain. Count the older instances that still drain.
      retires++;
      const draining = [...inflight].filter(([k, v]) => k !== r.x && k !== cur && v > 0).length;
      if (draining > 0) retireWhileDraining++;
      drainStart.set(cur, performance.now());
      cur = r.x;
    }
    for (const [k, v] of inflight) if (v === 0 && k !== r.x) {
      if (drainStart.has(k)) { drains.push(performance.now() - drainStart.get(k)); drainStart.delete(k); }
      inflight.delete(k);
    }
    maxLive = Math.max(maxLive, [...inflight.values()].filter((v) => v > 0).length);
  }
}
await Promise.all(Array.from({ length: conc }, worker));
drains.sort((a, b) => a - b);
const secs = (performance.now() - t0) / 1000;
console.log(JSON.stringify({ rate, latMs: lat, n, conc, rps: Math.round(n / secs), uncleanTraps: unclean_n.n, retires, retireWhileDraining, share: retires ? +(retireWhileDraining / retires).toFixed(3) : 0, maxInstancesWithTasks: maxLive, drainP50ms: +(drains[drains.length >> 1] ?? 0).toFixed(1), drainMaxms: +(drains.at(-1) ?? 0).toFixed(1), bad }));
