// PLAN.md 12d: the global check (`check_heap`).
// node bench/checkheap-test.mjs bench/out/app.wasm [bench/out/alloc_driver.wasm]
// A. App. For each kind of the test export `break_table` (one wild write into a table
//    entry of the shared memory, with no trap): 30 requests end (free runs, reserve pages), 10 wait
//    (task pages, wait records, adopted JS blocks). The check passes, then `break_table`, then the
//    runner check: it must fail, write one log line, and replace the instance (the 10 waiting tasks
//    get a 503, the next request is correct on the new instance).
// B. Allocator driver: the damage that the check finds. After a break, with no check, the next
//    allocations give blocks that overlap (as dfree.mjs). The check must find each break first.
// C. 12c: a throw after `handle` returned (in `readRes`, `drainLog`, `res_free`) on a damaged
//    instance is an alarm: `run` does not throw, the task gets a 503, and the global check runs.
//    `break_table` 28 sets the log length to 2^28 while 5 tasks wait. The first task that ends
//    reads the log past the memory end. The check finds the log and replaces the instance.
//    C2: `break_table` 17 makes the list of JS pages link to itself while a task waits (its second
//    wait: its request is a JS block that it adopted, long, so that `id` keeps it; until 8a: the fetch body). At its
//    resume the sum walk (`sumAdopted`) traps in the host code of the resume: an unclean trap, not
//    a throw at the resume point. Then `task_abort` traps too (the walk of `freeAdopted`). `run`
//    does not throw: an alarm "trap", and the check replaces the instance.
//    C3: `break_table` 18 makes the page list of a waiting task link to itself. At its resume the
//    sum walk traps (`step`). `task_abort` does not trap (its walk gives the page back, and that
//    ends the loop), but the trap was in the host code of the resume (`IN_HOST`): an alarm "trap",
//    not a clean trap, and the check replaces the instance.
// D. 12c: a check while the catch of another trapped task is still in the job queue. Task B gets a
//    sum alarm at its resume (`poke_wait` 1), task A an unclean trap just after its resume
//    (`fault_next_wait` 5 with 0 words). Both resume in the same job turn, B first: the check of
//    B's alarm runs while A's catch waits, so `TASK_TOP` and `OWNER` are A's. The host answers
//    CHECK_BUSY, and the check runs again at A's alarm. Since the first release run (PLAN.md "Status of the first
//    release run"), A's resume waits until B's catch left wasm (`enterWasm`, js/wait.js), so no check is busy.
//    Expect: 2 alarms, no busy check, no failed check, the instance stays, the next request is correct.
// E. 12c: the check that an alarm made due runs before the next resume. As D, but task A makes a
//    clean trap (a Roc `crash` after its first wait): no alarm, so nothing runs the check at A's
//    catch. Then task C resumes, still in the same job turn (no timer ran): the gate in the wait
//    import runs the check before C enters wasm. Since the first release run, the check at B's alarm is not busy
//    (A resumes only after B's catch), so it runs at once. Expect: no busy check, 1 check before C resumes, no
//    second check at the resume of C.
// F. 12c: as E, but a new request starts in place of the resume of C: the gate in `run` runs the
//    check before the new task enters wasm. Since the first release run: as E, the check ran at B's alarm.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner, check, CHECK_NAMES } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const failures = [];
const fail = (m) => { failures.push(m); console.log('FAIL', m); };
const tick = () => new Promise((r) => setTimeout(r, 0));

// Kinds of `break_table` (host/host.zig, hostlib/alloc.zig `breakTable`) and their arguments.
const KINDS = [
  [1, 'length of a free run'], [2, 'free bit of a small page in use'], [3, 'boundary tag of a free run'],
  [4, 'reserve page twice in the reserve'], [5, 'small page in use in the reserve'], [6, 'live count of a small page'],
  [7, 'free list of a small page points to a live block'], [8, 'back link of a task page list'],
  [9, 'page with room not in its list'], [10, 'slot of a large block'], [11, 'small page in use marked foreign'],
  [12, 'foreign unit below the pool'], [13, 'owner of a task slot'], [14, 'live byte count'],
  [15, 'count of used units'], [16, 'free mark'], [20, 'byte of .rodata', 64], [21, 'word of the canary', 7],
  [22, 'TASK_WAITING'], [23, 'index of a wait record'], [24, 'copy length of a wait record'], [25, 'log length'],
  [26, 'TASK_TOP'], [27, 'SUM_MODE'],
];

// A. ------------------------------------------------------------------------------------------
// Open each wait of `p` until it settles.
async function opened(p, gates) {
  let done = false;
  p.finally(() => (done = true));
  while (!done) {
    await tick();
    for (const [k, open] of gates) { gates.delete(k); open(); }
  }
  return p;
}

// io that waits until the test opens its gate `<kind>:<request id>`.
function gated(gates) {
  return (k, a, b) => {
    const id = k === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    const v = k === 1 ? `f:${id}` : `d:${id}`;
    return new Promise((res) => gates.set(`${k}:${id}`, () => res(v)));
  };
}
async function open(gates, key) {
  for (let i = 0; i < 50 && !gates.has(key); i++) await tick();
  const g = gates.get(key);
  if (!g) throw new Error(`no wait ${key}`);
  gates.delete(key);
  g();
  for (let i = 0; i < 3; i++) await tick();
}

async function partA(kind, name, arg = 0) {
  const gates = new Map();
  const lines = [];
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x0 = r.x;
  const runs = [];
  // Every 5th request makes 400 items (large blocks).
  for (let i = 0; i < 40; i++) runs.push(r.run(`${5000 + i} 0 6 ${i % 5 === 0 ? 400 : 20}`));
  // 30 tasks end: open their two waits. 10 stay at their first wait.
  for (let i = 0; i < 30; i++) {
    await open(gates, `1:${5000 + i}`);
    await open(gates, `2:${5000 + i}`);
  }
  const control = x0.check_heap();
  if (control !== 0) { fail(`A ${kind} ${name}: the check fails before the break (${control})`); return; }
  if (x0.task_waiting() !== 10) { fail(`A ${kind}: ${x0.task_waiting()} tasks wait, want 10`); return; }
  const hit = x0.break_table(kind, arg);
  if (hit !== 1) { fail(`A ${kind} ${name}: no target for the break: the test proves nothing`); return; }
  const code = x0.check_heap();
  const stays = r.checkHeap('test');
  // Open each wait until all tasks end (with no replace, the 10 tasks wait twice).
  const res = await opened(Promise.all(runs), gates);
  const cancelled = res.filter((v) => v.cancelled === 'heap').length;
  const next = await opened(r.run('7 0 3 5'), gates);
  const row = { kind, name, code, found: CHECK_NAMES[code] ?? '-', replaced: r.x !== x0, cancelled, logLines: lines.length, next: check('7', next.body ?? '', 3) };
  console.log('A', JSON.stringify(row));
  if (code === 0 || stays) fail(`A ${kind} ${name}: the check did not find it`);
  if (r.x === x0 || r.stats.retired !== 1 || r.stats.heapFails !== 1) fail(`A ${kind} ${name}: the instance was not replaced`);
  if (cancelled !== 10) fail(`A ${kind} ${name}: ${cancelled} waiting tasks got a 503, want 10`);
  if (lines.length !== 1 || !/heap check failed/.test(lines[0])) fail(`A ${kind} ${name}: log lines ${JSON.stringify(lines)}`);
  if (!row.next) fail(`A ${kind} ${name}: the next request is wrong: ${next.body ?? next.trap}`);
}
for (const [kind, name, arg] of KINDS) await partA(kind, name, arg);

// B. ------------------------------------------------------------------------------------------
const drv = new WebAssembly.Module(readFileSync(process.argv[3] ?? 'bench/out/alloc_driver.wasm'));
const AL = 1 | (4 << 8); // alloc, alignment 4
let nextId = 1;
function driver() {
  const x = new WebAssembly.Instance(drv, {}).exports;
  const live = new Map(); // id -> [owner, length]
  const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
  const alloc = (owner, len) => { const id = nextId++; run([[AL, owner, id, len]]); live.set(id, [owner, len]); return id; };
  const free = (owner, id) => { run([[2, owner, id, 0]]); live.delete(id); };
  const end = (owner) => { run([[4, owner, 0, 0]]); for (const [id, [o]] of live) if (o === owner) live.delete(id); };
  // Live blocks that share a byte.
  const overlaps = () => {
    const b = [...live].map(([id, [, len]]) => [x.ptr_of(id), len]).sort((p, q) => p[0] - q[0]);
    let n = 0;
    for (let i = 0; i + 1 < b.length; i++) if (b[i][0] + b[i][1] > b[i + 1][0]) n++;
    return n;
  };
  return { x, run, alloc, free, end, overlaps };
}
// Kinds whose damage gives blocks that overlap at the next allocations.
const OVERLAP = [[1, 'length of a free run'], [2, 'free bit of a small page in use'], [4, 'reserve page twice'], [5, 'small page in use in the reserve'], [7, 'free list points to a live block']];
for (const [kind, name] of OVERLAP) {
  nextId = 1;
  const d = driver();
  // Task 7 keeps blocks of 24 B, 100 B, 3,000 B and 9,000 B. Task 8 takes pages and ends: free runs
  // and reserve pages. A free of every other 3,000 B block of task 7 leaves runs of one unit.
  const keep = [];
  for (let i = 0; i < 40; i++) for (const len of [24, 100, 3000, 9000]) keep.push([d.alloc(7, len), len]);
  for (let i = 0; i < 300; i++) d.alloc(8, [24, 100, 2048, 5000][i % 4]);
  d.end(8);
  keep.filter(([, len], i) => len === 3000 && i % 8 === 2).forEach(([id]) => d.free(7, id));
  const before = d.x.check_tables();
  d.run([[13, 0, kind, kind === 7 ? 7 : 0]]);
  const code = d.x.check_tables();
  // With no check: more blocks of tasks 7 and 9, until the reserve is used up and memory grows.
  // Stop at the first overlap: on damaged lists a later allocation can loop for ever.
  let ov = 0;
  for (let i = 0; i < 400 && ov === 0; i++) {
    d.alloc(i % 2 ? 9 : 7, [24, 100, 3000, 2048][(i >> 1) % 4]);
    ov = d.overlaps();
  }
  console.log('B', JSON.stringify({ kind, name, before, code, found: CHECK_NAMES[code] ?? '-', overlapsWithNoCheck: ov }));
  if (before !== 0) fail(`B ${kind}: the check fails before the break (${before})`);
  if (code === 0) fail(`B ${kind} ${name}: the check did not find it`);
  if (ov === 0) fail(`B ${kind} ${name}: no blocks overlap with no check: the test proves nothing`);
}

// C. ------------------------------------------------------------------------------------------
{
  const gates = new Map();
  const lines = [];
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x0 = r.x;
  const runs = [];
  for (let i = 0; i < 5; i++) runs.push(r.run(`${6000 + i} 0 6 20`).catch((e) => ({ threw: String(e) })));
  await open(gates, '1:6000');
  if (x0.break_table(28, 1 << 28) !== 1) fail('C: no target for the break');
  await open(gates, '2:6000');
  const first = await runs[0];
  for (let i = 1; i < 5; i++) {
    for (const [k, g] of gates) { gates.delete(k); g(); }
    await tick();
  }
  const rest = await Promise.all(runs.slice(1));
  const row = { first: first.threw ?? `${first.status} ${first.alarm}`, alarms: r.stats.byAlarm, checks: r.stats.byCheck, fails: r.stats.heapFails, replaced: r.x !== x0, others: rest.map((v) => v.threw ? 'threw' : v.cancelled ?? 'body').join(' '), logLines: lines.length };
  console.log('C', JSON.stringify(row));
  if (first.threw) fail(`C: run threw: ${first.threw}`);
  else if (first.status !== 503 || first.alarm !== 'trap') fail(`C: the task got ${first.status} ${first.alarm}, want 503 alarm trap`);
  if (r.stats.heapFails !== 1 || r.x === x0) fail('C: the check after the alarm did not replace the instance');
  if (rest.some((v) => v.cancelled !== 'heap')) fail(`C: the other tasks: ${row.others}, want 4 cancels (heap)`);
}

{
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x0 = r.x;
  const p = r.run(`6100 0 6 20 - 0 ${'p'.repeat(64)}`).catch((e) => ({ threw: String(e) }));
  // At the second wait: the request (a JS block that the task adopted) is live.
  await open(gates, '1:6100');
  if (x0.break_table(17, 0) !== 1) fail('C2: no target for the break');
  await open(gates, '2:6100');
  const res = await p;
  const row = { res: res.threw ?? `${res.status} ${res.alarm} ${String(res.trap).slice(0, 40)}`, fails: r.stats.heapFails, replaced: r.x !== x0 };
  console.log('C2', JSON.stringify(row));
  if (res.threw) fail(`C2: run threw: ${res.threw}`);
  else if (res.status !== 503 || res.alarm !== 'trap') fail(`C2: the task got ${row.res}, want 503 alarm trap`);
  if (r.stats.heapFails !== 1 || r.x === x0) fail('C2: the check after the alarm did not replace the instance');
}

{
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x0 = r.x;
  const p = r.run('6200 0 6 20').catch((e) => ({ threw: String(e) }));
  if (x0.break_table(18, r.tasks.stats.started) !== 1) fail('C3: no target for the break');
  await open(gates, '1:6200');
  const res = await p;
  const row = { res: res.threw ?? `${res.status} ${res.alarm} ${String(res.trap).slice(0, 40)}`, hostAlarms: x0.alarms(), fails: r.stats.heapFails, replaced: r.x !== x0 };
  console.log('C3', JSON.stringify(row));
  if (res.threw) fail(`C3: run threw: ${res.threw}`);
  else if (res.status !== 503 || res.alarm !== 'trap') fail(`C3: the task got ${row.res}, want 503 alarm trap`);
  if (x0.alarms() !== 1) fail(`C3: the alarm counter of the host is ${x0.alarms()}, want 1`);
  if (r.stats.heapFails !== 1 || r.x === x0) fail('C3: the check after the alarm did not replace the instance');
}

{
  const gates = new Map();
  const lines = [];
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x0 = r.x;
  const pb = r.run('6300 0 6 20');
  const tb = r.tasks.stats.started;
  x0.set_wild(1, 0);
  x0.fault_next_wait(5);
  const pa = r.run('6301 0 6 20');
  if (x0.poke_wait(tb, 1, -16 >>> 0) === 0) fail('D: no target for the poke');
  for (let i = 0; i < 5; i++) await tick();
  for (const k of ['1:6300', '1:6301']) { gates.get(k)(); gates.delete(k); }
  const [rb, ra] = await Promise.all([pb, pa]);
  const next = await opened(r.run('7 0 3 5'), gates);
  const row = { b: `${rb.status} ${rb.alarm}`, a: `${ra.status} ${ra.alarm}`, busy: r.stats.heapBusy, checks: r.stats.byCheck, fails: r.stats.heapFails, replaced: r.x !== x0, next: check('7', next.body ?? '', 3) };
  console.log('D', JSON.stringify(row));
  if (rb.alarm !== 'sum' || ra.alarm !== 'trap') fail(`D: alarms ${row.b}, ${row.a}, want sum and trap`);
  if (r.stats.heapBusy !== 0) fail(`D: ${r.stats.heapBusy} checks saw a trapped task that is not aborted: an entry did not wait for the owner of the stack`);
  if (r.stats.heapFails !== 0 || r.x !== x0) fail(`D: the instance was replaced: ${JSON.stringify(lines)}`);
  if (!(r.stats.byCheck.alarm >= 1)) fail('D: no check ran after the alarms');
  if (!row.next) fail('D: the next request is wrong');
}

{
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x0 = r.x;
  const pb = r.run('6400 0 6 20');
  const tb = r.tasks.stats.started;
  const pa = r.run('6401 1 6 20');
  const pc = r.run('6402 0 6 20');
  if (x0.poke_wait(tb, 1, -16 >>> 0) === 0) fail('E: no target for the poke');
  for (let i = 0; i < 5; i++) await tick();
  // From here on, only promise jobs until C waits again: no timer can run the check.
  for (const k of ['1:6400', '1:6401']) { gates.get(k)(); gates.delete(k); }
  const [rb, ra] = await Promise.all([pb, pa]);
  const busy = r.stats.heapBusy, before = r.stats.byCheck.alarm ?? 0;
  gates.get('1:6402')();
  gates.delete('1:6402');
  for (let i = 0; i < 100 && !gates.has('2:6402'); i++) await Promise.resolve();
  const atResume = r.stats.byCheck.alarm ?? 0;
  for (const [k, g] of gates) { gates.delete(k); g(); }
  const rc = await opened(pc, gates);
  const row = { b: `${rb.status} ${rb.alarm}`, a: String(ra.trap).slice(0, 30), busy, checksBeforeC: before, checksAtResumeOfC: atResume, fails: r.stats.heapFails, replaced: r.x !== x0, c: check('6402', rc.body ?? '', 6) };
  console.log('E', JSON.stringify(row));
  if (rb.alarm !== 'sum' || ra.alarm || ra.body !== undefined) fail(`E: B ${row.b}, A ${row.a}: want an alarm sum and a clean trap`);
  if (busy !== 0 || before !== 1) fail(`E: ${busy} busy checks and ${before} checks before C resumed, want 0 and 1 (an entry did not wait for the owner of the stack)`);
  if (atResume !== 1) fail(`E: ${atResume} checks when C resumed, want 1 (the gate before the resume)`);
  if (r.stats.heapFails !== 0 || !row.c) fail('E: the instance was replaced, or C is wrong');
}

{
  const gates = new Map();
  const r = makeRunner(module, gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x0 = r.x;
  const pb = r.run('6500 0 6 20');
  const tb = r.tasks.stats.started;
  const pa = r.run('6501 1 6 20');
  if (x0.poke_wait(tb, 1, -16 >>> 0) === 0) fail('F: no target for the poke');
  for (let i = 0; i < 5; i++) await tick();
  for (const k of ['1:6500', '1:6501']) { gates.get(k)(); gates.delete(k); }
  const [rb, ra] = await Promise.all([pb, pa]);
  const busy = r.stats.heapBusy, before = r.stats.byCheck.alarm ?? 0;
  // `run` calls the gate before its task enters wasm, in this call.
  const pn = r.run('6502 0 6 20');
  const atStart = r.stats.byCheck.alarm ?? 0;
  const rn = await opened(pn, gates);
  const row = { b: `${rb.status} ${rb.alarm}`, a: String(ra.trap).slice(0, 30), busy, checksBefore: before, checksAtStart: atStart, fails: r.stats.heapFails, n: check('6502', rn.body ?? '', 6) };
  console.log('F', JSON.stringify(row));
  if (busy !== 0 || before !== 1) fail(`F: ${busy} busy checks and ${before} checks before the new task, want 0 and 1 (an entry did not wait for the owner of the stack)`);
  if (atStart !== 1) fail(`F: ${atStart} checks when the new task started, want 1 (the gate before \`handle\`)`);
  if (r.stats.heapFails !== 0 || !row.n) fail('F: the instance was replaced, or the new request is wrong');
}

console.log(failures.length ? `FAIL (${failures.length})` : 'PASS');
process.exit(failures.length ? 1 : 0);
