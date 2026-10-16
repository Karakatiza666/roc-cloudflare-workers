// PLAN.md 4b to 4e: the memory budget of the isolate.
// node --expose-gc bench/budget-test.mjs bench/out/app.wasm
// 4b: `js_grow` asks the budget before each grow. isolateBytes 16 MB, jsReserveBytes 0: a request that
//     holds 20 MB gets a 503 (cause oom), the other requests are correct, live bytes return to 0, the
//     instance stays and its memory stays at or under 16 MB.
// 4c: maxInstanceBytes 8 MB: the same request fails at 8 MB. No cap and isolateBytes 64 MB: it passes.
// 4d: 64 requests of 1 MB at once, isolateBytes 16 MB: the ones that do not fit get a 503, new requests
//     get a 503 (shed) for graceMs, the others are correct, live bytes return to 0.
// 4e: a dropped instance of 30 MB (a replace) counts in the budget until the FinalizationRegistry
//     callback reports it collected: a grow that would go over isolateBytes is denied until then.
// Each denied grow, each shed request and each replace writes one log line and has a counter (M11).
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
import { MB } from '../js/budget.js';
if (typeof gc !== 'function') throw new Error('run with node --expose-gc');
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
// The two waits of `deep!`. `slow`: ms of each wait.
const ioOf = (slow = 5) => async (kind, a, b) => {
  await sleep(slow);
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
let seq = 0;
// A request that holds `mb` MB across its waits. Depth 5, 10 items: small otherwise.
const req = (mb = 0) => { const id = String(700000 + seq++); return { id, text: `${id} 0 5 10 - ${mb}` }; };
const go = async (r, mb = 0, opts) => {
  const q = req(mb);
  const res = await r.run(q.text, opts);
  return { ...q, status: res.status, cause: res.cause, shed: res.shed, trap: res.trap, ok: !res.trap && check(q.id, res.body, 5), body: res.body };
};
const kind = (v) => (v.ok ? 'ok' : v.shed ? 'shed' : v.cause === 'oom' ? 'oom' : `other:${v.trap}`);
const tally = (vs) => vs.reduce((a, v) => ((a[kind(v)] = (a[kind(v)] ?? 0) + 1), a), {});
const mem = (r) => r.x.memory.buffer.byteLength;

// 4b
{
  const lines = [];
  const r = makeRunner(module, ioOf(), { isolateBytes: 16 * MB, jsReserveBytes: 0, graceMs: 0, log: (t) => lines.push(t) });
  const x0 = r.x;
  const warm = await Promise.all(Array.from({ length: 20 }, () => go(r)));
  // 10 good requests wait in the instance when the big one starts. Its OOM trap is at its start, in the
  // same call: a request that starts in the same tick would end the task state before the catch (12c, "a
  // check while the catch of a trapped task is in the job queue"), so the big one starts after them.
  const good = Array.from({ length: 10 }, () => go(r));
  const bigRes = go(r, 20);
  const mix = [await bigRes, ...(await Promise.all(good))];
  const small = await go(r, 8); // 8 MB fits
  const after = await go(r);
  const big = mix[0];
  console.log('4b', JSON.stringify({ warm: tally(warm), big: [big.status, big.cause], others: tally(mix.slice(1)), small8: kind(small), after: kind(after), mem: mem(r), maxMem: r.stats.maxMemBytes, live: r.x.live_bytes(), retired: r.stats.retired, denied: r.stats.budget.denied, oomCount: r.stats.oom, lines: lines.length }));
  if (tally(warm).ok !== 20) fail('4b: warm requests', tally(warm));
  if (big.status !== 503 || big.cause !== 'oom') fail('4b: the 20 MB request is not a 503 oom:', big.status, big.cause, big.trap);
  if (tally(mix.slice(1)).ok !== 10) fail('4b: the other requests are not correct', tally(mix.slice(1)));
  if (small.ok !== true || after.ok !== true) fail('4b: a request after the denial is not correct');
  if (r.x !== x0 || r.stats.retired !== 0) fail('4b: the instance did not stay');
  if (r.x.live_bytes() !== 0) fail('4b: live bytes are not 0:', r.x.live_bytes());
  if (r.stats.maxMemBytes > 16 * MB || mem(r) > 16 * MB) fail('4b: memory went over 16 MB:', r.stats.maxMemBytes, mem(r));
  // M11: one log line for each denied grow, and a counter.
  const denied = lines.filter((l) => /^grow denied/.test(l)).length;
  if (r.stats.budget.denied < 1 || denied !== r.stats.budget.denied) fail('4b: denied grows and their log lines differ:', r.stats.budget.denied, denied);
  if (r.stats.oom !== 1) fail('4b: oom counter', r.stats.oom);
}
// 4b: the grow step (M4, H9): `growStepBytes` is the least that one grow adds.
{
  const run = async (step) => {
    const r = makeRunner(module, ioOf(), { isolateBytes: 64 * MB, jsReserveBytes: 0, growStepBytes: step, log: () => {} });
    const m0 = mem(r);
    // 3,000 items: a heap of a few MB, built in many small allocations.
    const id = String(seq++);
    const res = await r.run(`${id} 0 5 3000`);
    return { ok: !res.trap && check(id, res.body, 5), init: m0, memSmall: mem(r), asked: r.stats.budget.asked };
  };
  const small = await run(64 * 1024);
  const big = await run(4 * MB);
  console.log('4b step', JSON.stringify({ small, big }));
  if (!small.ok || !big.ok) fail('4b step: a request failed');
  // With a step of 4 MB the first allocation of the request adds at least 4 MB, and there are fewer grows.
  if (big.asked >= small.asked) fail('4b step: a larger step must give fewer grows:', small.asked, big.asked);
  if (big.memSmall - big.init < 4 * MB) fail('4b step: the grow of 4 MB step was smaller:', big.memSmall - big.init);
}
// 4c
{
  const capped = makeRunner(module, ioOf(), { isolateBytes: 64 * MB, jsReserveBytes: 0, graceMs: 0, maxInstanceBytes: 8 * MB, log: () => {} });
  const a = await go(capped, 20);
  const smallOk = await go(capped, 2);
  const free = makeRunner(module, ioOf(), { isolateBytes: 64 * MB, jsReserveBytes: 0, graceMs: 0, log: () => {} });
  const b = await go(free, 20);
  console.log('4c', JSON.stringify({ capped: kind(a), capMem: mem(capped), small2: kind(smallOk), noCap: kind(b), noCapMem: mem(free), deniedCap: capped.stats.budget.deniedCap }));
  if (a.status !== 503 || a.cause !== 'oom') fail('4c: with the cap of 8 MB the request must fail:', kind(a));
  if (mem(capped) > 8 * MB) fail('4c: memory went over the cap:', mem(capped));
  if (!smallOk.ok) fail('4c: a small request must pass with the cap');
  if (capped.stats.budget.deniedCap < 1) fail('4c: the denial was not for the cap');
  if (!b.ok) fail('4c: with no cap the request must pass:', kind(b));
  if (capped.x.live_bytes() !== 0 || free.x.live_bytes() !== 0) fail('4c: live bytes are not 0');
}
// 4d
{
  const lines = [];
  const GRACE = 300;
  const r = makeRunner(module, ioOf(60), { isolateBytes: 16 * MB, jsReserveBytes: 0, graceMs: GRACE, log: (t) => lines.push(t) });
  const x0 = r.x;
  const wave = Array.from({ length: 64 }, () => go(r, 1));
  // The wave is running. A new request now is shed (a grow was denied in the last graceMs).
  await sleep(20);
  const during = await go(r);
  const res = await Promise.all(wave);
  const t = tally(res);
  // Still in the grace time: new requests are shed, also big ones (they must not reach the allocator).
  const inGrace = await go(r, 20);
  await sleep(GRACE + 100);
  const later = await go(r);
  console.log('4d', JSON.stringify({ wave: t, during: kind(during), inGrace: kind(inGrace), later: kind(later), mem: mem(r), maxMem: r.stats.maxMemBytes, live: r.x.live_bytes(), shedMem: r.stats.shedMem, oom: r.stats.oom, denied: r.stats.budget.denied }));
  if (t.ok === undefined || t.ok < 5) fail('4d: too few requests passed', t);
  if (!t.oom || t.oom < 1) fail('4d: no request got an OOM 503', t);
  if (!t.shed || t.shed < 1) fail('4d: no request was shed', t);
  if (Object.keys(t).some((k) => k.startsWith('other'))) fail('4d: a request failed in another way', t);
  if (during.shed !== true || inGrace.shed !== true) fail('4d: a new request in the grace time must be shed:', kind(during), kind(inGrace));
  if (!later.ok) fail('4d: after graceMs a new request must pass:', kind(later));
  if (res.some((v) => v.status !== undefined && v.status !== 503)) fail('4d: a failure without status 503');
  if (r.x !== x0 || r.stats.retired !== 0) fail('4d: the instance did not stay');
  if (r.x.live_bytes() !== 0) fail('4d: live bytes are not 0:', r.x.live_bytes());
  if (r.stats.maxMemBytes > 16 * MB) fail('4d: memory went over 16 MB:', r.stats.maxMemBytes);
  const shedLines = lines.filter((l) => /^request shed/.test(l)).length;
  if (shedLines !== r.stats.shedMem || r.stats.shedMem !== t.shed + 2) fail('4d: shed requests, counter and log lines differ:', shedLines, r.stats.shedMem, t.shed);
}
// 4e
{
  const lines = [];
  const r = makeRunner(module, ioOf(), { isolateBytes: 64 * MB, jsReserveBytes: 0, graceMs: 0, log: (t) => lines.push(t) });
  let old = r.x;
  const first = await go(r, 30);
  const oldBytes = old.memory.buffer.byteLength;
  r.replace('test');
  const dropped = r.budget.droppedBytes;
  // The old instance is held (`old`), so it cannot be collected yet. A grow that fits next to it only
  // when the dropped instance is not counted must be denied.
  const during = await go(r, 40);
  const real = oldBytes + mem(r);
  console.log('4e', JSON.stringify({ first: kind(first), oldMB: +(oldBytes / MB).toFixed(1), droppedMB: +(dropped / MB).toFixed(1), during: kind(during), realMB: +(real / MB).toFixed(1), totalMB: +(r.budget.total() / MB).toFixed(1) }));
  if (!first.ok) fail('4e: the 30 MB request failed:', kind(first));
  if (dropped !== oldBytes) fail('4e: the budget does not show the dropped instance:', dropped, oldBytes);
  if (during.cause !== 'oom') fail('4e: the grow must be denied while the old instance is not collected:', kind(during));
  if (real > 64 * MB) fail('4e: the memory of both instances went over 64 MB:', real);
  // Free the old instance. The callback ends its count.
  old = null;
  let ms = 0;
  for (; ms < 5000 && r.budget.droppedBytes > 0; ms += 20) { gc(); await sleep(20); }
  const collected = r.budget.droppedBytes === 0;
  const after = await go(r, 40);
  console.log('4e', JSON.stringify({ collected, afterMs: ms, after: kind(after), collectedCount: r.stats.budget.collected, replaces: r.stats.replaces }));
  if (!collected || r.stats.budget.collected !== 1) fail('4e: the callback did not report the old instance collected');
  if (!after.ok) fail('4e: after the callback the grow must pass:', kind(after));
  // M11: the replace has one line and a counter.
  if (r.stats.replaces.test !== 1 || lines.filter((l) => /^replace \(test\)/.test(l)).length !== 1) fail('4e: replace counter or log line', r.stats.replaces, lines.filter((l) => /^replace/.test(l)));
}
// 4e, M1: the new instance of a replace does not fit next to the dropped one: new requests are shed
// (not an OOM trap) until the callback.
{
  const lines = [];
  const r = makeRunner(module, ioOf(), { isolateBytes: 34 * MB, jsReserveBytes: 0, graceMs: 0, log: (t) => lines.push(t) });
  let old = r.x;
  const first = await go(r, 30);
  r.replace('test');
  const crowded = await go(r);
  const shedLines = lines.filter((l) => /^request shed: the old instance/.test(l)).length;
  console.log('4e M1', JSON.stringify({ first: kind(first), crowded: kind(crowded), reason: crowded.trap, shedLines }));
  if (!first.ok) fail('4e M1: the first request failed');
  if (crowded.shed !== true || crowded.status !== 503) fail('4e M1: a new request next to the uncollected old instance must be shed:', kind(crowded));
  if (shedLines !== 1) fail('4e M1: shed log lines', shedLines);
  old = null;
  let ms = 0;
  for (; ms < 5000 && r.budget.droppedBytes > 0; ms += 20) { gc(); await sleep(20); }
  const after = await go(r);
  if (!after.ok) fail('4e M1: after the callback a request must pass:', kind(after));
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
