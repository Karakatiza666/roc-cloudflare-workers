// PLAN.md 3c: a cancel ends the suspended stack (status 5), so memory stays flat and a
// replaced instance can be collected.
// node --expose-gc bench/cancel-test.mjs bench/out/app.wasm [batches=100] [warmup=200]
// 1. Batches of 100 requests whose io never resolves, and 10 good ones. The signal of each
//    of the 100 aborts while it waits, then the 10 good ones start, so they reuse the freed
//    memory before the cancelled tasks resume. Expect 503 for each, the good bodies correct, live
//    bytes 0, and flat RSS over the last 100 batches (10,000 cancels): less than 1 KB per
//    cancel (a suspended JSPI stack keeps about 6 KB, PLAN.md 3.0). RSS grows in the
//    first 200 batches (the V8 heap and stack pool warm up), then stays.
// 2. Replace an instance with 10 waiting tasks (M1): each gets a 503, and the
//    FinalizationRegistry callback reports the old instance collected.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
if (typeof gc !== 'function') throw new Error('run with node --expose-gc');
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const measured = Number(process.argv[3] ?? 100);
const warmup = Number(process.argv[4] ?? 200);
const batches = warmup + measured;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const never = (id) => id.startsWith('9');
const io = async (kind, a, b) => {
  const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
  if (never(id)) await new Promise(() => {});
  await sleep(kind === 1 ? 2 : 1);
  return (kind === 1 ? 'f:' : 'd:') + id;
};
const within = (p, ms) => Promise.race([p, sleep(ms).then(() => 'pending')]);
const waitFor = async (f, ms = 2000) => { for (let t = 0; t < ms && !f(); t += 1) await sleep(1); return f(); };
const rssMB = async () => { for (let i = 0; i < 3; i++) { gc(); await sleep(10); } return process.memoryUsage().rss / 2 ** 20; };

// 1.
{
  const r = makeRunner(module, 'b', io);
  let cancels = 0, bad = 0, pending = 0, rssWarm = 0;
  // A task that waits for the whole run keeps the page of the wait records in the host,
  // so a new wait record reuses the record of a cancelled task (else that page goes back).
  const anchorAc = new AbortController();
  const anchor = r.run('999999999 0 5 10', { signal: anchorAc.signal });
  await waitFor(() => r.x.task_waiting() === 1);
  const t0 = performance.now();
  for (let k = 0; k < batches; k++) {
    const acs = Array.from({ length: 100 }, () => new AbortController());
    const lost = acs.map((ac, i) => r.run(`${900000 + k * 100 + i} 0 5 10`, { signal: ac.signal }).then((x) => x.cancelled === 'signal' && x.status === 503));
    if (!(await waitFor(() => r.x.task_waiting() >= 101))) { fail('1: the tasks did not wait, batch', k); pending += 100; break; }
    for (const ac of acs) ac.abort();
    // New tasks start before the cancelled ones resume, so their wait records reuse the freed ones.
    const goodIds = Array.from({ length: 10 }, (_, i) => String(100000 + k * 10 + i));
    const good = goodIds.map((id) => r.run(`${id} 0 5 10`).then((x) => !x.trap && check(id, x.body, 5)));
    const res = await within(Promise.all(lost), 2000);
    if (res === 'pending') { pending += 100; break; }
    cancels += res.filter(Boolean).length;
    bad += (await Promise.all(good)).filter((ok) => !ok).length;
    if (bad) break;
    if (k === warmup - 1) rssWarm = await rssMB();
  }
  const ms = performance.now() - t0;
  anchorAc.abort();
  if ((await within(anchor, 1000)).cancelled !== 'signal') fail('1: the anchor task was not cancelled');
  const rssEnd = await rssMB();
  const x = r.x;
  const perCancelKB = ((rssEnd - rssWarm) * 1024) / (measured * 100);
  console.log('1. cancels:', { cancels, pending, bad, rssWarm: rssWarm.toFixed(1), rssEnd: rssEnd.toFixed(1), perCancelKB: perCancelKB.toFixed(3), ms: Math.round(ms), live: x.live_bytes(), waiting: x.task_waiting(), saved: x.task_saved(), traps: r.stats.traps, retired: r.stats.retired, mem: x.memory.buffer.byteLength });
  if (cancels !== batches * 100 || pending !== 0) fail('1: not all tasks were cancelled');
  if (bad !== 0) fail('1: bad bodies');
  if (x.live_bytes() !== 0 || x.task_waiting() !== 0 || x.task_saved() !== 0) fail('1: live bytes, waiting tasks or saved bytes not 0');
  if (r.stats.traps !== 0 || r.stats.retired !== 0) fail('1: a cancel counted as a trap');
  if (perCancelKB >= 1) fail('1: RSS grows by', perCancelKB.toFixed(2), 'KB per cancel');
}
// 2.
{
  let collected = false;
  const reg = new FinalizationRegistry(() => (collected = true));
  const r = makeRunner(module, 'b', io);
  const ps = Array.from({ length: 10 }, (_, i) => r.run(`${990000 + i} 0 5 10`).then((x) => ({ status: x.status, cancelled: x.cancelled })));
  await waitFor(() => r.x.task_waiting() === 10);
  const waiting = r.x.task_waiting();
  reg.register(r.x, 'old');
  r.replace();
  const res = await within(Promise.all(ps), 1000);
  const ok = res !== 'pending' && res.every((x) => x.status === 503 && x.cancelled === 'replace');
  let ms = 0;
  for (; ms < 5000 && !collected; ms += 50) { gc(); await sleep(50); }
  const next = await r.run('123456 0 5 10');
  console.log('2. replace:', { waiting, cancelled503: ok, collected, afterMs: ms, tableSize: r.tasks.size, next: check('123456', next.body ?? '', 5) });
  if (waiting !== 10 || !ok) fail('2: the 10 tasks did not get a 503');
  if (!collected) fail('2: the old instance was not collected');
  if (!check('123456', next.body ?? '', 5)) fail('2: the new instance is wrong');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
