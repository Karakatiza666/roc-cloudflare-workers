// PLAN.md 4h, 4j and the decided point of 12e on the app (variant b): the counters of the host, the idle
// reset after a passed idle check, and the end of the suspicion of an alarm at that check.
// node bench/idle-test.mjs bench/out/app.wasm
// 4h  `leak_next(n)` makes one task keep a block: `leaked_at_end` shows its bytes (class of 100: 128, 10,000:
//     12,288). 200 normal requests leave `leaked_at_end` 0. `live_peak` and `heap_bytes` are set.
// 4j  1,000 requests of mixed sizes (40 at once), then idle: `heap_used` returns to the value of the
//     warm instance (the first idle reset), `check_heap` passes, the pool does not shrink, the next requests are
//     correct. A block that stays live (a JS block): no reset, no damage; after it is freed, the reset is done.
//     A task that waits: `idle_reset` is refused, and the task ends with a correct body.
// 12e `resumeCheck: "afterAlarm"`: an alarm makes each resume check its sum (`set_suspect`). A passed idle check
//     ends that: a later resume does not run the sum check (`sum_checks` stays).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tick = () => new Promise((r) => setTimeout(r, 0));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const io = async (kind, a, b) => { await sleep(1); return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]; };
let seq = 0;
const go = async (r, items = 5, depth = 3) => {
  const id = String(920000 + seq++);
  const res = await r.run(`${id} 0 ${depth} ${items}`);
  return !res.trap && check(id, res.body, depth);
};
const wave = async (r, n, pick) => (await Promise.all(Array.from({ length: n }, (_, i) => go(r, ...pick(i))))).filter((ok) => !ok).length;

// 4h: the leak counter, the peak, the heap bytes
{
  const r = makeRunner(module, 'b', io, { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x = r.x;
  const bad = await wave(r, 200, (i) => [[5, 20, 200][i % 3], 3 + (i % 10)]);
  const c0 = r.counters();
  console.log('4h normal', JSON.stringify({ bad, ...c0 }));
  if (bad !== 0) fail('4h: bad bodies');
  if (c0.leakedAtEnd !== 0) fail(`4h: 200 normal requests leaked ${c0.leakedAtEnd} bytes`);
  if (c0.livePeak === 0 || c0.liveBytes !== 0 || c0.heapBytes === 0 || c0.heapBytes % 4096 !== 0) fail('4h: peak, live bytes or heap bytes', JSON.stringify(c0));
  if (c0.heapBytes < c0.heapUsed) fail('4h: heap_bytes is below heap_used');
  for (const [n, want] of [[100, 128], [10000, 12288]]) {
    const before = x.leaked_at_end();
    x.leak_next(n);
    const ok = await go(r);
    const got = x.leaked_at_end() - before;
    console.log('4h leak', JSON.stringify({ asked: n, leaked: got, ok, live: x.live_bytes() }));
    if (got !== want) fail(`4h: a task that kept ${n} bytes: leaked_at_end +${got}, want +${want}`);
    if (!ok || x.live_bytes() !== 0) fail('4h: the request after a leak, or live bytes after taskEnd');
  }
  if (!(await go(r)) || x.leaked_at_end() !== 128 + 12288) fail('4h: a normal request after the leaks changed the counter');
}

// 4j: the reset after a passed idle check
const MIX = (i) => [[5, 20, 200, 2000][i % 4], 3 + (i % 25)];
{
  const lines = [];
  const waits = [];
  const ctx = { waitUntil: (p) => waits.push(p) };
  const r = makeRunner(module, 'b', io, { heapCheckEvery: 0, heapCheckWhenIdle: true, log: (t) => lines.push(t) });
  const x = r.x;
  // Warm: the first requests, and the first idle reset. Its `heap_used` is the base.
  await r.run(`1 0 3 5`, { ctx });
  await Promise.all(waits);
  const base = x.heap_used();
  console.log('4j warm', JSON.stringify({ resets: r.stats.idleResets, base, pool: x.heap_bytes() }));
  if (r.stats.idleResets !== 1) fail('4j: no idle reset after the first request:', r.stats.idleResets, r.stats.idleResetsSkipped);
  let bad = 0;
  for (let k = 0; k < 25; k++) bad += await wave(r, 40, MIX);
  // The last task ended; its idle timer has not run yet.
  const high = x.heap_used(), pool = x.heap_bytes(), resetsBefore = r.stats.idleResets;
  await sleep(30);
  const after = x.heap_used();
  const chk = x.check_heap();
  const next = await go(r, 200, 10);
  console.log('4j', JSON.stringify({ requests: 1000, bad, base, high, after, pool: [pool, x.heap_bytes()], resets: [resetsBefore, r.stats.idleResets], resetBytes: r.stats.idleResetBytes, check: chk, live: x.live_bytes(), next }));
  if (bad !== 0 || !next) fail('4j: bad bodies');
  if (high <= base) fail(`4j: heap_used ${high} before the idle point is not above the base ${base}: the test proves nothing`);
  if (after !== base) fail(`4j: heap_used ${after} after the idle point, want the base ${base}`);
  if (chk !== 0) fail('4j: check_heap fails after the reset:', chk);
  if (x.heap_bytes() !== pool) fail('4j: the pool changed');
  if (r.stats.idleResets <= resetsBefore || x.idle_resets() !== r.stats.idleResets) fail('4j: reset counters', r.stats.idleResets, x.idle_resets());
  if (r.stats.idleResetBytes < high - base) fail('4j: idleResetBytes is less than the bytes given back', r.stats.idleResetBytes);
  if (r.x !== x || r.stats.retired !== 0 || r.stats.heapFails !== 0) fail('4j: the instance was replaced');
}
// A block that stays live (a JS block, outside the tasks): no reset, no damage.
{
  const r = makeRunner(module, 'b', io, { heapCheckEvery: 0, heapCheckWhenIdle: true, log: () => {} });
  const x = r.x;
  await go(r);
  await sleep(10);
  const p = x.js_alloc(100);
  new Uint8Array(x.memory.buffer, p, 100).fill(77);
  const resets0 = r.stats.idleResets;
  let bad = 0;
  for (let k = 0; k < 5; k++) bad += await wave(r, 40, MIX);
  const high = x.heap_used();
  await sleep(30);
  const kept = x.heap_used() === high;
  const intact = new Uint8Array(x.memory.buffer, p, 100).every((b) => b === 77);
  const chk = x.check_heap();
  bad += await wave(r, 40, MIX);
  await sleep(30);
  const intact2 = new Uint8Array(x.memory.buffer, p, 100).every((b) => b === 77);
  console.log('4j live block', JSON.stringify({ resets: [resets0, r.stats.idleResets], skipped: r.stats.idleResetsSkipped, kept, intact, intact2, check: chk, bad }));
  if (r.stats.idleResets !== resets0 || r.stats.idleResetsSkipped < 1) fail('4j live block: a reset was done, or none was tried', r.stats.idleResets, r.stats.idleResetsSkipped);
  if (!kept || !intact || !intact2 || chk !== 0 || bad !== 0) fail('4j live block: damage');
  // The block goes: the next idle point resets.
  x.res_free(p);
  await go(r);
  await sleep(30);
  if (r.stats.idleResets !== resets0 + 1 || x.heap_used() >= high) fail('4j live block: no reset after the block was freed', r.stats.idleResets, x.heap_used());
  if (x.check_heap() !== 0) fail('4j live block: check_heap fails after the reset');
}

// A task that waits: `idle_reset` is refused, and the task ends with a correct body.
{
  const gates = new Map();
  const r = makeRunner(module, 'b', (k, a, b) => {
    const id = k === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    return new Promise((res) => gates.set(`${k}:${id}`, () => res(k === 1 ? `f:${id}` : `d:${id}`)));
  }, { heapCheckEvery: 0, heapCheckWhenIdle: false, log: () => {} });
  const x = r.x;
  const id = String(940000 + seq++);
  const p = r.run(`${id} 0 3 5`);
  for (let i = 0; i < 100 && !gates.has(`1:${id}`); i++) await tick();
  const refused = x.idle_reset();
  gates.get(`1:${id}`)();
  for (let i = 0; i < 100 && !gates.has(`2:${id}`); i++) await tick();
  gates.get(`2:${id}`)();
  const res = await p;
  console.log('4j waiting task', JSON.stringify({ reset: refused, ok: !res.trap && check(id, res.body, 3), check: x.check_heap() }));
  if (refused !== 0) fail('4j: idle_reset reset while a task waits');
  if (res.trap || !check(id, res.body, 3) || x.check_heap() !== 0) fail('4j: the waiting task was damaged');
}

// 12e: a passed idle check ends the suspicion of an alarm (`afterAlarm`)
{
  const lines = [];
  const gates = new Map();
  const gated = (k, a, b) => {
    const id = k === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    return new Promise((res) => gates.set(`${k}:${id}`, () => res(k === 1 ? `f:${id}` : `d:${id}`)));
  };
  const open = async (key) => {
    for (let i = 0; i < 100 && !gates.has(key); i++) await tick();
    if (!gates.has(key)) throw new Error(`no wait ${key}`);
    const g = gates.get(key);
    gates.delete(key);
    g();
  };
  const full = async () => {
    const id = String(930000 + seq++);
    const p = r.run(`${id} 0 3 5`);
    await open(`1:${id}`);
    await open(`2:${id}`);
    const res = await p;
    return !res.trap && check(id, res.body, 3);
  };
  const r = makeRunner(module, 'b', gated, { resumeCheck: 'afterAlarm', heapCheckEvery: 0, heapCheckWhenIdle: true, log: (t) => lines.push(t) });
  const x = r.x;
  x.fault_next_wait(2); // an unclean trap: an alarm, and `set_suspect(1)`
  const a = await r.run(`${seq++} 0 3 5`);
  const s0 = x.sum_checks();
  const okControl = await full(); // the suspicion is on: each of its 2 resumes checks its sum
  const s1 = x.sum_checks();
  await sleep(10); // the idle check of the control request passes: the suspicion ends
  const okAfter = await full();
  const s2 = x.sum_checks();
  console.log('12e suspect', JSON.stringify({ alarm: a.alarm, sumChecks: [s0, s1, s2], idleChecks: r.stats.byCheck.idle, okControl, okAfter }));
  if (a.alarm !== 'trap') fail('12e: no alarm');
  if (s1 - s0 !== 2) fail(`12e: with the suspicion on, a request with 2 resumes made ${s1 - s0} sum checks, want 2 (the test proves nothing)`);
  if (!(r.stats.byCheck.idle >= 1)) fail('12e: no idle check');
  if (s2 !== s1) fail(`12e: after a passed idle check the resumes made ${s2 - s1} sum checks, want 0`);
  if (!okControl || !okAfter) fail('12e: a request was wrong');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
