// Unclean trap after a wild write: what happens to the tasks that drain on the old instance?
// node wild.mjs <words> [n=20000] [rate=0.005] [latMs=20]
import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const [words, n = 20000, rate = 0.005, lat = 20] = process.argv.slice(2).map(Number);
const m = new WebAssembly.Module(readFileSync('out/app_v.wasm'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async () => { await sleep(-Math.log(1 - Math.random()) * lat); return 'x'; };
const r = makeRunner(m, 'b', io, { noFallback: true });
let seed = 7;
const setWild = (x) => x.set_wild(seed++, words);
setWild(r.x);
const want = (await r.run('2 50')).body;
const retiredAt = new Map();
const s = { good: 0, goodOnDraining: 0, badBody: 0, badOnDraining: 0, trapGood: 0, trapGoodOnDraining: 0, wild: 0, otherErr: 0 };
let i = 0;
async function worker() {
  while (i < n) {
    i++;
    const wild = Math.random() < rate;
    const x = r.x;
    let res;
    try { res = await r.run(wild ? '97 0' : '2 50'); } catch (e) { s.otherErr++; continue; }
    if (r.x !== x) setWild(r.x);
    if (wild) { s.wild++; continue; }
    // "On draining": the instance was retired while this task ran.
    const draining = r.x !== x;
    s.good++;
    if (draining) s.goodOnDraining++;
    if (res.body === undefined) { s.trapGood++; if (draining) s.trapGoodOnDraining++; }
    else if (res.body !== want) { s.badBody++; if (draining) s.badOnDraining++; }
  }
}
await Promise.all(Array.from({ length: 64 }, worker));
console.log(JSON.stringify({ words, n, rate, ...s, retired: r.stats.retired }));
