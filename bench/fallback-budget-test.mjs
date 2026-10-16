// PLAN.md 4f (M9): the budget of the fallback (one instance for each request).
// node --expose-gc bench/fallback-budget-test.mjs bench/out09/app.wasm
// The module is the 10-09 build (data-first), so `makeRunner(module, 'b')` falls back to variant a.
// 64 requests at once, isolateBytes 32 MB, jsReserveBytes 0. A new instance starts only when its
// memory fits the budget, else the request waits in the queue (queueLimit). A dropped instance counts
// until it is collected (M10), and workerd collects in seconds, so the test calls gc() every 25 ms.
// Expect: all 64 pass, some of them waited, no request got an OOM, and the memory of the instances
// that exist (a WeakRef of each `WebAssembly.Memory`, sampled at each wait and each ms) never goes over 32 MB.
// Part 2: queueLimit 10: the requests above the queue are shed (503).
// Part 3: a request in the queue leaves with 503 when its signal aborts.
// Part 4: no GC at all (the test holds each instance). When no instance is live, a waiting request starts although
// the dropped instances count (PLAN.md "Fallback queue in workerd"): all requests pass, none waits for a collection.
// The idle start (PLAN.md "Fallback queue in workerd"): the rule is that an instance starts although dropped ones count only
// when no instance is live, so at most one such instance is alive at a time. It does not say that the dropped ones are
// collected between two idle starts: V8 collects them when it wants, so garbage piles up across idle starts. Each idle
// start puts at most one instance over the limit. So the memory bound is the limit plus one instance for each idle start
// (a bound of one instance fails under load, when a collection does not run between two idle starts), and the rule itself
// is checked on each start (`watchIdle`): no instance is live at an idle start, and only one idle instance is alive.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
import { MB } from '../js/budget.js';
if (typeof gc !== 'function') throw new Error('run with node --expose-gc');
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
// A request that waits for ever (a queue that nothing wakes) must fail the test, not hang it.
setTimeout(() => { console.log('FAIL the test did not end in 60 s: a request waits for ever'); process.exit(1); }, 60_000);
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };

// All memories of all instances, as weak references.
const memories = [];
const RealInstance = WebAssembly.Instance;
WebAssembly.Instance = class extends RealInstance {
  constructor(m, imports) {
    super(m, imports);
    if (this.exports.memory) memories.push(new WeakRef(this.exports.memory));
  }
};
const aliveBytes = () => { let n = 0; for (const w of memories) { const m = w.deref(); if (m) { n += m.buffer.byteLength; maxOne = Math.max(maxOne, m.buffer.byteLength); } } return n; };
let peak = 0, peakCount = 0, maxOne = 0;
const sample = () => {
  const n = aliveBytes();
  if (n > peak) peak = n;
  const c = memories.filter((w) => w.deref()).length;
  if (c > peakCount) peakCount = c;
};
const io = async (kind, a, b) => {
  sample();
  await sleep(5);
  sample();
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
const timer = setInterval(sample, 1);
const gcTimer = setInterval(() => gc(), 25);
// A result holds `x`, the instance of its request, and the runner could not collect it (M10) while the test holds
// the result. So keep only the fields that the test needs.
const light = (p) => p.then(({ x, ...rest }) => rest);
const kind = (res, id) => (res.trap ? (res.shed ? `shed(${res.reason})` : res.cause === 'oom' ? 'oom' : 'trap') : check(id, res.body, 5) ? 'ok' : 'bad');
const tally = (ks) => ks.reduce((a, k) => ((a[k] = (a[k] ?? 0) + 1), a), {});

// The rule of the idle start, on each start of the budget: `startIdle` gives true only when no instance is live, and the
// instance that `add` gets next is the idle one, alive until its `drop`. Returns the maxima, filled while the runner runs.
const watchIdle = (b) => {
  const w = { maxLiveAtIdle: 0, maxIdleAlive: 0 };
  let next = false, alive = 0;
  const idle = new Set();
  const startIdle = b.startIdle.bind(b), add = b.add.bind(b), drop = b.drop.bind(b);
  b.startIdle = () => {
    const live = b.liveCount, was = b.stats.idleStarts;
    const ok = startIdle();
    if (ok && b.stats.idleStarts > was) {
      next = true;
      w.maxLiveAtIdle = Math.max(w.maxLiveAtIdle, live);
    }
    return ok;
  };
  b.add = (m) => {
    add(m);
    if (next) {
      next = false;
      idle.add(m);
      w.maxIdleAlive = Math.max(w.maxIdleAlive, ++alive);
    }
  };
  b.drop = (m) => {
    if (idle.delete(m)) alive--;
    drop(m);
  };
  return w;
};
// 1.
{
  const r = makeRunner(module, 'b', io, { isolateBytes: 32 * MB, jsReserveBytes: 0, log: () => {} });
  const idle = watchIdle(r.budget);
  if (!r.stats.fallback) fail('1: the module is not data-first: the runner did not fall back');
  const ids = Array.from({ length: 64 }, (_, i) => String(800000 + i));
  let maxQueued = 0;
  const watch = setInterval(() => { maxQueued = Math.max(maxQueued, r.queued); }, 1);
  const res = await Promise.all(ids.map((id) => light(r.run(`${id} 0 5 10`))));
  clearInterval(watch);
  sample();
  const t = tally(res.map((x, i) => kind(x, ids[i])));
  console.log('1.', JSON.stringify({ t, queuedRequests: r.stats.queued, maxQueued, peakMB: +(peak / MB).toFixed(1), peakInstances: peakCount, instancesMade: memories.length, oom: r.stats.oom, denied: r.stats.budget.denied, maxTotalMB: +(r.budget.stats.maxTotal / MB).toFixed(1) }));
  if (t.ok !== 64) fail('1: not all 64 requests passed', t);
  if (r.stats.queued === 0) fail('1: no request waited in the queue: the test proves nothing');
  if (r.stats.oom !== 0) fail('1: a request got an OOM');
  const idleStarts = r.budget.stats.idleStarts;
  console.log('1. idle', JSON.stringify({ idleStarts, maxLiveAtIdle: idle.maxLiveAtIdle, maxIdleAlive: idle.maxIdleAlive, instanceMB: +(maxOne / MB).toFixed(2) }));
  // The rule: an idle start with no live instance, one idle instance at a time.
  if (idle.maxLiveAtIdle !== 0) fail('1: an idle start with an instance live:', idle.maxLiveAtIdle);
  if (idle.maxIdleAlive > 1) fail('1: more than one idle instance alive at a time:', idle.maxIdleAlive);
  // The bound: over the limit by at most one instance for each idle start (the dropped ones are not collected yet).
  if (peak > 32 * MB + maxOne * idleStarts) fail('1: the instances went over 32 MB and one instance for each of', idleStarts, 'idle starts:', peak, maxOne);
  if (r.budget.stats.maxTotal > 32 * MB + maxOne * idleStarts) fail('1: the budget went over 32 MB and one instance for each of', idleStarts, 'idle starts:', r.budget.stats.maxTotal);
}
// 2.
{
  const r = makeRunner(module, 'b', io, { isolateBytes: 32 * MB, jsReserveBytes: 0, queueLimit: 10, log: () => {} });
  const ids = Array.from({ length: 64 }, (_, i) => String(810000 + i));
  const res = await Promise.all(ids.map((id) => light(r.run(`${id} 0 5 10`))));
  const ks = res.map((x, i) => kind(x, ids[i]));
  const t = tally(ks);
  const shed = ks.filter((k) => k.startsWith('shed')).length;
  console.log('2.', JSON.stringify({ t, shedMem: r.stats.shedMem }));
  if (shed === 0 || !ks.every((k) => k === 'ok' || k === 'shed(queue is full)')) fail('2: with queueLimit 10 the requests above the queue must be shed', t);
  if (r.stats.shedMem !== shed) fail('2: shed counter', r.stats.shedMem, shed);
  if (res.some((x) => x.trap && x.status !== 503)) fail('2: a shed request without status 503');
}
// 3.
{
  const r = makeRunner(module, 'b', io, { isolateBytes: 32 * MB, jsReserveBytes: 0, log: () => {} });
  const acs = Array.from({ length: 40 }, () => new AbortController());
  const ids = acs.map((_, i) => String(820000 + i));
  const ps = ids.map((id, i) => light(r.run(`${id} 0 5 10`, { signal: acs[i].signal })));
  const waiting = r.queued;
  for (const ac of acs.slice(20)) ac.abort();
  const res = await Promise.all(ps);
  const ks = res.map((x, i) => kind(x, ids[i]));
  const left = ks.slice(20).filter((k) => k.startsWith('shed(request was cancelled')).length;
  console.log('3.', JSON.stringify({ waiting, left, queueNow: r.queued, passed: ks.slice(0, 20).filter((k) => k === 'ok').length }));
  if (waiting === 0) fail('3: no request waited');
  if (left === 0) fail('3: no request left the queue at its abort');
  if (r.queued !== 0) fail('3: the queue is not empty at the end');
  if (ks.slice(0, 20).some((k) => k !== 'ok')) fail('3: a request that stays must pass');
}
// 4.
{
  clearInterval(gcTimer);
  const r = makeRunner(module, 'b', io, { isolateBytes: 32 * MB, jsReserveBytes: 0, log: () => {} });
  const ids = Array.from({ length: 64 }, (_, i) => String(830000 + i));
  const held = []; // the results keep `x`: no instance is collected
  const all = Promise.all(ids.map((id) => r.run(`${id} 0 5 10`).then((res) => (held.push(res), res))));
  const hung = Symbol('hung');
  const res = await Promise.race([all, sleep(10_000).then(() => hung)]);
  if (res === hung) fail('4: requests wait for a collection that does not come:', r.queued, 'in the queue');
  else {
    const ks = res.map((x, i) => kind(x, ids[i]));
    console.log('4.', JSON.stringify({ t: tally(ks), queuedRequests: r.stats.queued, idleStarts: r.budget.stats.idleStarts, collected: r.budget.stats.collected, droppedCount: r.budget.droppedCount }));
    if (ks.some((k) => k !== 'ok')) fail('4: not all requests passed', tally(ks));
    if (r.budget.stats.idleStarts === 0) fail('4: no idle start: the test proves nothing');
    if (r.queued !== 0) fail('4: the queue is not empty at the end');
  }
}
clearInterval(timer);
clearInterval(gcTimer);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
