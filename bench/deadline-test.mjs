// PLAN.md 3b: deadlines and request.signal, with the real app (variant b).
// node bench/deadline-test.mjs bench/out/app.wasm
// 1. taskDeadlineMs 100, io that never resolves for one request. The next request cancels
//    it: it gets a 503, and live bytes return to 0.
// 2. Abort the signal of a waiting request: it is cancelled at once.
// 3. A Scheduled and a Queue task with one wait of 300 ms end with a body (wait deadline
//    100 ms, wall limit 15 min). With the wall limit at 200 ms, each is cancelled.
//    A Fetch task with the same wait is cancelled at about 100 ms.
// The kind is a field of the task table today; 8b gives the real events.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
// id -> the time of its first wait (ms), or 'never'. Other ids: 3 ms and 1 ms.
const plan = new Map();
const io = async (kind, a, b) => {
  const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
  const p = plan.get(id);
  if (kind === 1 && p === 'never') await new Promise(() => {});
  await sleep(kind === 1 ? (p ?? 3) : 1);
  return (kind === 1 ? 'f:' : 'd:') + id;
};
// A result, or 'pending' after `ms`.
const within = (p, ms) => Promise.race([p, sleep(ms).then(() => 'pending')]);
// Normal requests every 25 ms until `stop()`: each one checks the table (3b).
const ticker = (r) => {
  let on = true, n = 0, bad = 0;
  const loop = (async () => {
    while (on) {
      const id = String(60000 + n++);
      const x = await r.run(`${id} 0 5 10`);
      if (x.trap || !check(id, x.body, 5)) bad++;
      await sleep(25);
    }
  })();
  return async () => { on = false; await loop; return { n, bad }; };
};

// 1.
{
  const r = makeRunner(module, 'b', io, { taskDeadlineMs: 100 });
  plan.set('8001', 'never');
  const a = r.run('8001 0 5 10');
  await sleep(150);
  const waitingBefore = r.x.task_waiting();
  const b = await r.run('8002 0 5 10');
  const ra = await within(a, 1000);
  const x = r.x;
  console.log('1. deadline:', { waitingBefore, a: ra === 'pending' ? ra : { status: ra.status, cancelled: ra.cancelled }, b: check('8002', b.body ?? '', 5), live: x.live_bytes(), waiting: x.task_waiting(), saved: x.task_saved(), traps: r.stats.traps, retired: r.stats.retired });
  if (waitingBefore !== 1) fail('1: the task did not wait');
  if (ra === 'pending' || ra.status !== 503 || ra.cancelled !== 'deadline') fail('1: the task was not cancelled');
  if (!check('8002', b.body ?? '', 5)) fail('1: the next request is wrong');
  if (x.live_bytes() !== 0 || x.task_waiting() !== 0) fail('1: live bytes or waiting tasks not 0');
  if (r.stats.traps !== 0 || r.stats.retired !== 0) fail('1: a cancel counted as a trap');
}
// 2.
{
  const r = makeRunner(module, 'b', io);
  plan.set('8101', 'never');
  const ac = new AbortController();
  const a = r.run('8101 0 5 10', { signal: ac.signal });
  await sleep(50);
  const t0 = performance.now();
  ac.abort();
  const ra = await within(a, 1000);
  const ms = performance.now() - t0;
  const x = r.x;
  console.log('2. signal:', { a: ra === 'pending' ? ra : { status: ra.status, cancelled: ra.cancelled }, ms: Math.round(ms * 10) / 10, live: x.live_bytes(), waiting: x.task_waiting() });
  if (ra === 'pending' || ra.status !== 503 || ra.cancelled !== 'signal') fail('2: the task was not cancelled');
  if (ms > 20) fail('2: the cancel was not at once');
  if (x.live_bytes() !== 0 || x.task_waiting() !== 0) fail('2: live bytes or waiting tasks not 0');
}
// 3.
for (const [kind, wallMs, want] of [['Scheduled', undefined, 'body'], ['Queue', undefined, 'body'], ['Scheduled', 200, 'cancel'], ['Queue', 200, 'cancel'], ['Fetch', undefined, 'cancel']]) {
  const r = makeRunner(module, 'b', io, { taskDeadlineMs: 100, wallMs });
  const id = String(8200 + Math.floor(Math.random() * 1000));
  plan.set(id, 300);
  const stop = ticker(r);
  const t0 = performance.now();
  const res = await r.run(`${id} 0 5 10`, { kind });
  const ms = Math.round(performance.now() - t0);
  const tk = await stop();
  const got = res.cancelled ? 'cancel' : check(id, res.body ?? '', 5) ? 'body' : 'bad';
  console.log(`3. ${kind}, wall ${wallMs ?? 'default'}:`, { got, ms, reason: res.cancelled, ticks: tk.n, tickBad: tk.bad, live: r.x.live_bytes() });
  if (got !== want) fail(`3: ${kind}: want ${want}`);
  if (want === 'cancel' && kind !== 'Fetch' && (ms < 190 || ms > 260)) fail(`3: ${kind}: cancelled at ${ms} ms, want about 200`);
  if (kind === 'Fetch' && (ms < 90 || ms > 160)) fail(`3: Fetch: cancelled at ${ms} ms, want about 100`);
  if (tk.bad !== 0 || r.x.live_bytes() !== 0) fail('3: bad bodies or live bytes');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
