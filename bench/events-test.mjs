// PLAN.md 4g (M11): each event writes one log line and has a counter. The case of each row of M11, in 3b,
// 3c, 4b to 4e and 12c to 12e, runs on the app, and the test counts the lines and the counter:
//   grow denied (4b)   request shed (4d)   alarm trap, alarm sum (12c)   failed global check, every and idle (12d, 12e)
//   replace (4e, M1)   cancel by deadline, by signal (3b), by a replace (3c)   double free caught, free refused (6e)
// Also the decided point of 12c: a trap in `task_cancel` is an alarm (`cancel` in the alarm counters).
// node bench/events-test.mjs bench/out/app.wasm
// A case fails when its line is missing, or its counter and its lines differ in number. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
import { MB } from '../js/budget.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tick = () => new Promise((r) => setTimeout(r, 0));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
// io that waits until the test opens its gate `<kind>:<id>`.
const gated = (gates) => (k, a, b) => {
  const id = k === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
  return new Promise((res) => gates.set(`${k}:${id}`, () => res(k === 1 ? `f:${id}` : `d:${id}`)));
};
// Wait until the task waits at gate `key`.
async function gateWait(gates, key) {
  for (let i = 0; i < 100 && !gates.has(key); i++) await tick();
  if (!gates.has(key)) throw new Error(`no wait ${key}`);
}
async function gateOpen(gates, key) {
  await gateWait(gates, key);
  const g = gates.get(key);
  gates.delete(key);
  g();
}
let seq = 0;
const req = (mb = 0, depth = 3) => { const id = String(910000 + seq++); return { id, text: `${id} 0 ${depth} 5 - ${mb}` }; };
const good = async (r, opts) => { const q = req(); const res = await r.run(q.text, opts); return !res.trap && check(q.id, res.body, 3); };
// `lines` of kind `re`, and a check that the counter has the same number of them (at least `min`).
const count = (lines, re) => lines.filter((l) => re.test(l)).length;
function expectEvent(tag, lines, re, counter, min = 1) {
  const n = count(lines, re);
  console.log(tag, JSON.stringify({ lines: n, counter }));
  if (n < min) fail(`${tag}: no log line ${re}`);
  else if (n !== counter) fail(`${tag}: ${n} log lines ${re}, counter ${counter}`);
}

// grow denied (4b) and request shed (4d)
{
  const lines = [];
  const r = makeRunner(module, io, { isolateBytes: 16 * MB, jsReserveBytes: 0, graceMs: 300, log: (t) => lines.push(t) });
  const big = req(20);
  const res = await r.run(big.text);
  if (res.cause !== 'oom') fail('grow denied: the 20 MB request is not an OOM 503', res.trap);
  expectEvent('grow denied', lines, /^grow denied/, r.stats.budget.denied);
  const shed = await r.run(req().text);
  if (shed.shed !== true) fail('shed: a request in the grace time is not shed');
  expectEvent('request shed', lines, /^request shed/, r.stats.shedMem);
}

// alarm: an unclean trap (cause trap), and a resume whose sum differs (cause sum) (12c)
{
  const lines = [];
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x = r.x;
  x.fault_next_wait(2); // the next wait traps with `unreachable`: unclean
  const a = await r.run(req().text);
  if (a.alarm !== 'trap') fail('alarm trap: the result is not an alarm', a.trap);
  expectEvent('alarm trap', lines, /^alarm trap: task \d+/, r.stats.byAlarm.trap);
  if (x.alarms() !== 1) fail('alarm trap: the host counter `alarms` is', x.alarms());
  // A sum alarm: `poke_wait` 1 changes `Wait.low` of the waiting task, so its sum differs at the resume.
  const q = req();
  const p = r.run(q.text);
  await gateWait(gates, `1:${q.id}`);
  const id = r.tasks.stats.started; // task ids count from 1
  if (x.poke_wait(id, 1, 16) === 0) fail('alarm sum: poke_wait found no waiting task');
  await gateOpen(gates, `1:${q.id}`);
  const s = await p;
  if (s.alarm !== 'sum') fail('alarm sum: the result is', s.alarm ?? s.body);
  expectEvent('alarm sum', lines, /^alarm sum: task \d+/, r.stats.byAlarm.sum);
  expectEvent('alarms (all)', lines, /^alarm /, r.stats.alarms);
}

// failed global check: every N requests (12e), and at idle (12e)
for (const mode of ['every', 'idle']) {
  const lines = [];
  const r = makeRunner(module, io, { heapCheckEvery: mode === 'every' ? 2 : 0, heapCheckWhenIdle: mode === 'idle', log: (t) => lines.push(t) });
  const x0 = r.x;
  for (let i = 0; i < 3; i++) await good(r, {});
  if (x0.break_table(14, 0) !== 1) fail(`failed check ${mode}: no target`); // live byte count + 16
  for (let i = 0; i < 4 && r.x === x0; i++) { await good(r, {}); await sleep(5); }
  if (r.x === x0) fail(`failed check ${mode}: the instance was not replaced`);
  expectEvent(`failed check (${mode})`, lines, new RegExp(`^heap check failed \\(${mode}\\)`), r.stats.heapFails);
  if (r.stats.byCheck[mode] < 1) fail(`failed check ${mode}: byCheck`);
}

// replace (M1)
{
  const lines = [];
  const r = makeRunner(module, io, { log: (t) => lines.push(t) });
  r.replace('test');
  expectEvent('replace', lines, /^replace \(test\)/, r.stats.replaces.test);
}

// cancel: a deadline (3b), the signal (3b), and a replace (3c)
{
  const lines = [];
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { taskDeadlineMs: 50, heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  // 3b, deadline: a wait that never ends. The next request cancels it.
  const stuck = req();
  const pStuck = r.run(stuck.text);
  await sleep(80);
  const q = req();
  const pq = r.run(q.text);
  await gateOpen(gates, `1:${q.id}`);
  await gateOpen(gates, `2:${q.id}`);
  const [rs, rq] = await Promise.all([pStuck, pq]);
  if (rs.cancelled !== 'deadline' || !check(q.id, rq.body, 3)) fail('cancel deadline: results', rs.cancelled, rq.trap);
  expectEvent('cancel (deadline)', lines, /^task cancelled \(deadline\)/, r.tasks.stats.byReason.deadline);
  // 3b, signal
  const ac = new AbortController();
  const sg = req();
  const pSig = r.run(sg.text, { signal: ac.signal });
  await gateWait(gates, `1:${sg.id}`);
  ac.abort();
  const rsig = await pSig;
  if (rsig.cancelled !== 'signal') fail('cancel signal: result', rsig.cancelled, rsig.trap);
  expectEvent('cancel (signal)', lines, /^task cancelled \(signal\)/, r.tasks.stats.byReason.signal);
  // 3c, a replace cancels the waiting tasks: its own line says how many, and each cancel counts.
  const w1 = req(), w2 = req();
  const pw = [r.run(w1.text), r.run(w2.text)];
  await tick();
  const before = lines.length;
  r.replace('test');
  const rw = await Promise.all(pw);
  const rl = lines.slice(before).filter((l) => /^replace \(test\)/.test(l));
  console.log('cancel (replace)', JSON.stringify({ cancelled: rw.map((v) => v.cancelled), replaceLines: rl, counter: r.tasks.stats.byReason.replace }));
  if (rw.some((v) => v.cancelled !== 'test') || r.tasks.stats.byReason.test !== 2) fail('cancel replace: the 2 waiting tasks were not cancelled by the replace');
  if (rl.length !== 1 || !/2 tasks cancelled/.test(rl[0])) fail('cancel replace: the replace line must say 2 tasks cancelled', rl);
}

// double free caught and free refused: counters of the host (6e), one line each (M11)
{
  const lines = [];
  const r = makeRunner(module, io, { log: (t) => lines.push(t) });
  const x = r.x;
  await good(r, {});
  x.bad_free(1);
  if (x.double_frees() !== 1) fail('double free: the host counter is', x.double_frees());
  await good(r, {}); // the line comes after the next task
  expectEvent('double free caught', lines, /^double free caught: 1 new/, r.stats.doubleFrees);
  x.bad_free(2);
  if (x.dealloc_miss() !== 1) fail('free refused: the host counter is', x.dealloc_miss());
  await good(r, {});
  expectEvent('free refused', lines, /^free refused: 1 new/, r.stats.deallocMiss);
  // The counters of the host in one record.
  const c = r.counters();
  if (c.doubleFrees !== 1 || c.deallocMiss !== 1 || c.liveBytes !== 0) fail('counters()', JSON.stringify(c));
  if (!r.checkHeap('test')) fail('the heap is not sound after the wrong frees');
}

// A trap in `task_cancel` is an alarm (decided in 12c). `break_table` 17 makes the walk of the JS pages
// loop for ever, and `task_cancel` of a waiting task walks them: it traps (the `step` limit).
{
  const lines = [];
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x0 = r.x;
  x0.js_alloc(16); // a JS block that stays: a JS page exists
  const ac = new AbortController();
  const q = req();
  const p = r.run(q.text, { signal: ac.signal });
  await gateWait(gates, `1:${q.id}`);
  if (x0.break_table(17, 0) !== 1) fail('trap in cancel: no target');
  ac.abort();
  const res = await p;
  console.log('trap in cancel', JSON.stringify({ result: res.cancelled, alarms: r.stats.alarms, byAlarm: r.stats.byAlarm, heapFails: r.stats.heapFails }));
  if (res.cancelled !== 'signal') fail('trap in cancel: the task is not cancelled', res.trap);
  expectEvent('alarm cancel', lines, /^alarm cancel: task \d+/, r.stats.byAlarm.cancel ?? 0);
  if (r.stats.alarms !== 1) fail('trap in cancel: alarms', r.stats.alarms);
  // The alarm made the global check due: it finds the loop of the JS page list, and the instance is replaced.
  if (r.stats.heapFails !== 1 || r.x === x0) fail('trap in cancel: the check after the alarm did not replace the damaged instance');
  const n = req();
  const pn = r.run(n.text);
  await gateOpen(gates, `1:${n.id}`);
  await gateOpen(gates, `2:${n.id}`);
  const rn = await pn;
  if (rn.trap || !check(n.id, rn.body, 3)) fail('trap in cancel: the next request is wrong');
}
// A cancel with no trap is no alarm.
{
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const ac = new AbortController();
  const q = req();
  const p = r.run(q.text, { signal: ac.signal });
  await gateWait(gates, `1:${q.id}`);
  ac.abort();
  await p;
  if (r.stats.alarms !== 0) fail('a normal cancel counted as an alarm');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
