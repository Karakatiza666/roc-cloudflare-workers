// PLAN.md 8e, "Fallback queue in workerd": why does part 1 of bench/fallback-budget-test.mjs fail under load?
// node --expose-gc research/fallback-idle/probe.mjs bench/out09/app.wasm
// It runs part 1 (64 requests at once, isolateBytes 32 MB, a gc() every 25 ms) and records each `add`, `drop` and idle
// start of the budget. For each run it prints: the old bound (the budget over 32 MB and one instance), the idle starts,
// the most instances that were live when an idle instance started (the rule: 0), the idle instances alive at the same
// time (the rule: 1), and the longest run of idle starts with no collection between them.
import { readFileSync } from 'node:fs';
import { makeRunner } from '../../bench/core.js';
import { MB } from '../../js/budget.js';
if (typeof gc !== 'function') throw new Error('run with node --expose-gc');
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  await sleep(5);
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
const runs = Number(process.argv[3] ?? 1);
for (let k = 0; k < runs; k++) {
  const gcTimer = setInterval(() => gc(), 25);
  const r = makeRunner(module, 'b', io, { isolateBytes: 32 * MB, jsReserveBytes: 0, log: () => {} });
  const b = r.budget;
  const ev = [];
  let idleNext = false, idleAlive = 0, maxIdleAlive = 0, maxLiveAtIdle = 0, maxOne = 0;
  const idleMems = new Set();
  const startIdle = b.startIdle.bind(b), add = b.add.bind(b), drop = b.drop.bind(b);
  b.startIdle = () => {
    const liveBefore = b.liveCount, idleBefore = b.stats.idleStarts;
    const ok = startIdle();
    if (ok && b.stats.idleStarts > idleBefore) {
      idleNext = true;
      maxLiveAtIdle = Math.max(maxLiveAtIdle, liveBefore);
      ev.push({ e: 'idle', liveBefore, droppedMB: +(b.droppedBytes / MB).toFixed(1), collected: b.stats.collected });
    }
    return ok;
  };
  b.add = (m) => {
    add(m);
    maxOne = Math.max(maxOne, m.buffer.byteLength);
    if (idleNext) {
      idleNext = false;
      idleMems.add(m);
      idleAlive++;
      maxIdleAlive = Math.max(maxIdleAlive, idleAlive);
      ev[ev.length - 1].totalMB = +(b.total() / MB).toFixed(1);
    }
  };
  b.drop = (m) => {
    if (idleMems.delete(m)) idleAlive--;
    drop(m);
  };
  const ids = Array.from({ length: 64 }, (_, i) => String(800000 + i));
  await Promise.all(ids.map((id) => r.run(`${id} 0 5 10`).then(({ x, ...rest }) => rest)));
  clearInterval(gcTimer);
  // The longest run of idle starts with no collection between two of them.
  let run = 0, longest = 0;
  for (let i = 0; i < ev.length; i++) {
    run = i > 0 && ev[i].collected === ev[i - 1].collected ? run + 1 : 1;
    longest = Math.max(longest, run);
  }
  const over = b.stats.maxTotal > 32 * MB + maxOne;
  const worst = ev.reduce((a, e) => (e.totalMB > (a?.totalMB ?? 0) ? e : a), null);
  console.log(`run ${k}: oldBound ${over ? 'FAILS' : 'ok'}, maxTotal ${(b.stats.maxTotal / MB).toFixed(1)} MB, instance ${(maxOne / MB).toFixed(2)} MB, idleStarts ${b.stats.idleStarts}, ` +
    `maxLiveAtIdle ${maxLiveAtIdle}, maxIdleAlive ${maxIdleAlive}, longestIdleRunNoGC ${longest}, collected ${b.stats.collected}, worstIdleStart ${JSON.stringify(worst)}`);
  if (over) console.log('  idle starts:', JSON.stringify(ev.slice(0, 8)));
}
process.exit(0);
