// PLAN.md 2c: the task table of the host, and the two open points of 2c.
// node bench/tasktable-test.mjs bench/out/app.wasm
// 1. A throw into a waiting task (from outside `js_await`, at its resume point) skips
//    `waitEnd`. `task_abort(id)` frees its saved copy and pages: live bytes 0.
// 2. OOM in `waitBegin` (the Wait record, then the stack copy) is a clean trap for the
//    task, and leaves no Wait record.
// 3. Task slots: 400 requests at once. The host has `task_slots()` slots: the requests
//    above it get a 503 (a shed), and the instance stays.
import { readFileSync } from 'node:fs';
import { makeRunner, benchOps, check, eventBlock, outcomeBody } from './core.js';
import { makeBridge } from '../js/bridge.js';
import { makePins } from '../js/helpers.js';
import { makeTaskTable } from '../js/tasks.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const io = async (kind, a, b) => {
  await sleep(kind === 1 ? 3 : 1);
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};

// 1. The import of the victims throws after a wait, with no status: as a V8 RangeError at the
//    resume point. JS then calls task_abort(id), as the runner does.
{
  const tasks = makeTaskTable();
  const cell = { x: null };
  const bridge = makeBridge(cell, tasks, { ops: benchOps(io), pins: makePins(), log: () => {} });
  const victims = new Set();
  // (task id, arg ptr, arg len, out ptr): the first argument is the task.
  const js_await = async (...args) => {
    if (victims.has(args[0])) { await sleep(5); throw new Error('forced throw into the waiting task'); }
    return bridge.js_await(...args);
  };
  const ex = new WebAssembly.Instance(module, { env: { js_await: new WebAssembly.Suspending(js_await), js_call: bridge.js_call, js_grow: () => 1 } }).exports;
  cell.x = ex;
  ex.set_free_mark(crypto.getRandomValues(new Uint32Array(1))[0] | 1);
  ex.init(1);
  const handle = WebAssembly.promising(ex.handle);
  const run = async (req, victim) => {
    const t = tasks.begin(ex);
    if (victim) victims.add(t.id);
    // PLAN.md 8b: the request text is the body of a `Fetch` event.
    const [p, len] = eventBlock(ex, req);
    try {
      const blk = await handle(p, len, t.id);
      return { body: outcomeBody(ex, blk) };
    } catch (e) {
      return { trap: String(e), freed: ex.task_abort(t.id) };
    } finally {
      tasks.end(t);
    }
  };
  const ids = Array.from({ length: 40 }, (_, i) => String(5000 + i));
  const isVictim = (i) => i % 8 === 3;
  const res = await Promise.all(ids.map((id, i) => run(`${id} 0 5 20`, isVictim(i))));
  let bad = 0, thrown = 0, unclean = 0;
  res.forEach((r, i) => {
    if (isVictim(i)) {
      if (!r.trap) bad++;
      else { thrown++; if (r.freed === -1) unclean++; }
    } else if (r.trap || !check(ids[i], r.body, 5)) bad++;
  });
  const after = await run('5100 0 5 20', false);
  const live = ex.live_bytes(), waiting = ex.task_waiting(), saved = ex.task_saved(), miss = ex.dealloc_miss();
  console.log('1. throw into a waiting task:', { thrown, unclean, bad, next: check('5100', after.body ?? '', 5), live, waiting, saved, miss });
  if (thrown !== 5 || unclean !== 0) fail('1: each victim must abort clean');
  if (bad !== 0 || !check('5100', after.body ?? '', 5)) fail('1: bad bodies');
  if (live !== 0 || waiting !== 0 || saved !== 0 || miss !== 0) fail('1: live bytes, waiting tasks, saved bytes or dealloc_miss not 0');
}

// 2. `fail_alloc_at(n)` in the io of the first wait. The last two allocations before the second wait starts
//    are in `waitBegin`: the Wait record, then the stack copy. Since 8a other allocations come first (the result
//    block, the program of the second wait and its argument block), so a control run counts them (`alloc_count`):
//    `d` allocations from the end of the first io to the start of the second. n = d - 1: the Wait record, n = d:
//    the stack copy. Until 8a: n = 1 and 2.
async function allocsBetween(victim) {
  let c1 = 0, c2 = 0, r;
  const io0 = async (kind, a, b) => {
    await sleep(kind === 1 ? 3 : 1);
    const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    if (kind === 1 && id === victim) { c1 = r.x.alloc_count(); return ''; }
    if (kind === 2 && id === victim) c2 = r.x.alloc_count();
    return (kind === 1 ? 'f:' : 'd:') + id;
  };
  r = makeRunner(module, io0);
  await r.run(`${victim} 0 5 10`);
  return c2 - c1;
}
const d = await allocsBetween('7003');
for (const [n, what] of [[d - 1, 'the Wait record'], [d, 'the stack copy']]) {
  const victim = '7003';
  let r, dbCalls = 0;
  const io2 = async (kind, a, b) => {
    await sleep(kind === 1 ? 3 : 1);
    const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    if (kind === 1 && id === victim) { r.x.fail_alloc_at(n); return ''; }
    if (kind === 2 && id === victim) dbCalls++;
    return (kind === 1 ? 'f:' : 'd:') + id;
  };
  r = makeRunner(module, io2);
  const x0 = r.x;
  const ids = Array.from({ length: 20 }, (_, i) => String(7000 + i));
  const res = await Promise.all(ids.map((id) => r.run(`${id} 0 5 10`)));
  let bad = 0;
  const trapped = [];
  res.forEach((x, i) => { if (x.trap) trapped.push(ids[i]); else if (!check(ids[i], x.body, 5)) bad++; });
  const x = r.x;
  const live = x.live_bytes(), waiting = x.task_waiting(), miss = x.dealloc_miss();
  console.log(`2. OOM at allocation ${n} of ${d} (${what}):`, { trapped: trapped.join(), dbCalls, bad, walkFailed: r.stats.walkFailed, retired: r.stats.retired, same: x === x0, live, waiting, miss });
  if (trapped.join() !== victim || dbCalls !== 0) fail(`2.${n}: only the victim must trap, before its second wait starts`);
  if (bad !== 0) fail(`2.${n}: bad bodies`);
  if (r.stats.walkFailed !== 0 || r.stats.retired !== 0 || x !== x0) fail(`2.${n}: the trap was not clean`);
  if (live !== 0 || waiting !== 0 || miss !== 0) fail(`2.${n}: live bytes (a Wait record left?), waiting tasks or dealloc_miss not 0`);
}

// 3. 400 requests at once, each waits 30 ms.
{
  const r = makeRunner(module, async (kind, a, b) => { await sleep(30); return io(kind, a, b); });
  const x0 = r.x;
  const slots = x0.task_slots();
  const ids = Array.from({ length: 400 }, (_, i) => String(10000 + i));
  const res = await Promise.all(ids.map((id) => r.run(`${id} 0 5 10`)));
  let ok = 0, shed = 0, other = 0;
  res.forEach((x, i) => {
    if (x.shed && x.status === 503) shed++;
    else if (!x.trap && check(ids[i], x.body, 5)) ok++;
    else other++;
  });
  const after = await r.run('11000 0 5 10');
  const x = r.x;
  console.log('3. 400 at once:', { slots, ok, shed, other, retired: r.stats.retired, same: x === x0, next: check('11000', after.body ?? '', 5), live: x.live_bytes(), waiting: x.task_waiting() });
  if (ok !== slots || shed !== 400 - slots || other !== 0) fail('3: want', slots, 'bodies and', 400 - slots, 'sheds');
  if (r.stats.retired !== 0 || x !== x0) fail('3: the instance was replaced');
  if (!check('11000', after.body ?? '', 5)) fail('3: the next request is wrong');
  if (x.live_bytes() !== 0 || x.task_waiting() !== 0) fail('3: live bytes or waiting tasks not 0');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
