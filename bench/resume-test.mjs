// PLAN.md 12a, 12b: the sum at each wait and the check at resume.
// node bench/resume-test.mjs bench/out/app.wasm [afterAlarm]   (the second argument: the revert check of C)
// The io of each task waits until the test releases it, so the test writes while the task waits.
// A. 12a: `poke_wait` adds -16 to `Wait.low` of a waiting task: that task gets a 503 (alarm "sum").
// B. 12a: `poke_wait` changes a byte of a JS block that the task adopted (its request, long, so that `id` keeps it
//    across the waits): that task gets a 503 (alarm "sum"). Until 8a the target was the body of the first wait;
//    the bridge frees each result block before the resume, so the request is the JS block that stays.
// C. 12b: one byte of a task's string (in its pages) changes while it waits, with no trap. The other
//    tasks resume first and end with correct bodies, then the task gets a 503 (alarm "sum").
// D. 12b: the length of the response block goes up by 1 MB just before the resume: a 503 (alarm "block"). Since 8a
//    JS writes a result into a block of 256 B or more, so the change must be larger than the room of the block.
// E. 12b: one task alone. Between its wait and its resume only `js_alloc` (its response block) runs:
//    the resume checks the sum (`sum_checks` + 1).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const resumeCheck = process.argv[3] ?? 'always';
const failures = [];
const fail = (m) => { failures.push(m); console.log('FAIL', m); };
const tick = () => new Promise((r) => setTimeout(r, 0));

// io that waits until `release(kind, id)`. The fetch body is long, so it stays a heap block.
function gatedRunner(opts = {}) {
  const gates = new Map();
  const io = (kind, a, b) => {
    const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    const v = kind === 1 ? `f:${id}:${'x'.repeat(40)}` : `d:${id}`;
    return new Promise((res) => gates.set(`${kind}:${id}`, () => res(v)));
  };
  const r = makeRunner(module, 'b', io, { resumeCheck, ...opts });
  // Start a task. It runs up to its first wait in this call. In a fresh runner, task ids are 1, 2, ...
  r.start = (id, extra = '') => {
    const p = r.run(`${id} 0 5 10${extra}`);
    return { p, tid: r.tasks.stats.started };
  };
  r.release = async (kind, id) => {
    for (let i = 0; i < 50 && !gates.has(`${kind}:${id}`); i++) await tick();
    const g = gates.get(`${kind}:${id}`);
    if (!g) throw new Error(`no wait ${kind} of ${id}`);
    gates.delete(`${kind}:${id}`);
    g();
    for (let i = 0; i < 5; i++) await tick();
  };
  return r;
}

// The body with no write: the same request on a clean runner.
async function good(id, extra) {
  const r = gatedRunner();
  const { p } = r.start(id, extra);
  await r.release(1, id);
  await r.release(2, id);
  return (await p).body;
}
const show = (res) => (res.body !== undefined ? `body ${res.body.slice(-40)}` : `${res.status ?? '-'} ${res.alarm ?? res.cancelled ?? ''} ${String(res.trap).slice(0, 40)}`);

async function expectAlarm(name, id, cause, poke, extra) {
  const want = await good(id, extra);
  const r = gatedRunner();
  const { p, tid } = r.start(id, extra);
  const at = await poke(r, tid);
  if (!at) {
    fail(`${name}: the write found no target: the test proves nothing`);
    return;
  }
  // The poke may have released the first wait already. After an alarm the second wait never starts.
  await r.release(1, id).catch(() => {});
  await r.release(2, id).catch(() => {});
  const res = await p;
  console.log(`${name}:`, show(res), '| body correct:', res.body === want);
  if (res.status !== 503 || res.alarm !== cause) fail(`${name}: want 503 alarm ${cause}, got ${show(res)}`);
}

// A. Wait.low of the first wait.
await expectAlarm('A Wait.low', '701', 'sum', async (r, tid) => r.x.poke_wait(tid, 1, -16 >>> 0));

// B. The adopted JS block (the request), at the second wait. The parts after the 4th are not read by the app.
await expectAlarm('B adopted JS block', '702', 'sum', async (r, tid) => {
  await r.release(1, '702');
  return r.x.poke_wait(tid, 2, 0x01);
}, ` - 0 ${'p'.repeat(64)}`);

// C. A byte of the task's own string `level-1-of-request-<id>` (bench/app.roc `deep!`), which
// the task reads after the wait. 7 other tasks wait too, and resume first.
{
  const id = '703', others = ['711', '712', '713', '714', '715', '716', '717'];
  const want = await good(id);
  const wantOther = new Map();
  for (const o of others) wantOther.set(o, await good(o));
  const r = gatedRunner();
  const v = r.start(id);
  const os = others.map((o) => ({ o, ...r.start(o) }));
  const m = Buffer.from(r.x.memory.buffer);
  const tag = Buffer.from(`level-1-of-request-${id}`);
  let hits = 0;
  for (let at = m.indexOf(tag); at >= 0; at = m.indexOf(tag, at + 1)) {
    r.x.poke_wait(at + tag.length - 1, 4, 0x01); // the last digit of the id: 3 -> 2
    hits++;
  }
  if (!hits) fail('C: the string was not found: the test proves nothing');
  for (const { o } of os) await r.release(1, o);
  for (const { o } of os) await r.release(2, o);
  let okOthers = 0;
  for (const { o, p } of os) {
    const res = await p;
    if (res.body === wantOther.get(o)) okOthers++;
    else fail(`C: other task ${o}: ${show(res)}`);
  }
  await r.release(1, id);
  await r.release(2, id).catch(() => {});
  const res = await v.p;
  console.log(`C one byte in a task page (${hits} copies, resumeCheck ${resumeCheck}):`, show(res), '| body correct:', res.body === want, '| others correct:', okOthers);
  if (res.status !== 503 || res.alarm !== 'sum') fail(`C: want 503 alarm sum, got ${show(res)}`);
}

// D. The length of the response block of the second wait.
await expectAlarm('D length of the response block', '704', 'block', async (r, tid) => {
  await r.release(1, '704');
  return r.x.poke_wait(tid, 3, 1 << 20);
});

// E. Only js_alloc runs between the wait and the resume.
{
  const r = gatedRunner();
  const { p } = r.start('705');
  const c0 = r.x.sum_checks();
  await r.release(1, '705');
  const c1 = r.x.sum_checks();
  await r.release(2, '705');
  const res = await p;
  console.log('E js_alloc only: sum checks at the first resume', c1 - c0, '|', show(res));
  if (c1 - c0 !== 1) fail(`E: ${c1 - c0} checks at the resume, want 1`);
  if (res.body !== (await good('705'))) fail('E: wrong body');
}

console.log(failures.length ? `FAIL (${failures.length})` : 'PASS');
process.exit(failures.length ? 1 : 0);
