// PLAN.md 12e: the global check with no alarm (every `heapCheckEvery` requests, and when idle).
// node bench/checkevery-test.mjs bench/out/app.wasm [revert]
// Two wild writes with no trap, into shared memory that no task sum covers:
//   T: an allocator counter: the count of used units (`break_table` kind 15). No task reads it, so no sum
//      differs and no alarm comes first. (Before 4g it was the free bit of a small page in use, kind 2:
//      the wrong bit sometimes gave a page to two tasks, a sum differed, and the check of the alarm
//      replaced the instance while requests ran: the test failed in about 40 % of the runs.)
//   C: constant data: one byte of the Roc string literal "http://echo/f?id=" ("id" to "ie"). Each
//      later task sends a wrong URL, and its body is wrong with no trap and no alarm.
// 8 loops send requests (io of 0 to 3 ms), so a task is always in flight. 201 requests, the
// write, 300 more requests. For T and C:
//   1. `heapCheckEvery` 100, no idle check: the instance is replaced (one failed check, "every")
//      within 100 requests after the write. No failed check before it. One log line.
//   2. Only idle checks: no replace while the requests run. When they stop, the idle check
//      replaces the instance. Each request has a `ctx`: the idle check is in `ctx.waitUntil`.
//   After each part: the requests that start on the new instance give correct bodies.
// "revert": the runner of each part has no 12e (`heapCheckEvery` 0, no idle check), as before
// 12e. Then the instance is never replaced (the test fails), and with C later requests get wrong bodies.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const revert = process.argv[3] === 'revert';
const failures = [];
const fail = (m) => { failures.push(m); console.log('FAIL', m); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (k, a, b) => {
  await sleep(Math.random() * 3);
  return k === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
// The write comes 1 request after an "every" check, so the next one is about 100 requests later.
const DEPTH = 6, BEFORE = 201, AFTER = 300, LOOPS = 8;

// The address of a byte string in the data of the instance (below the heap pool), or 0.
function find(x, s) {
  const pat = new TextEncoder().encode(s);
  const u8 = new Uint8Array(x.memory.buffer);
  const end = Math.min(u8.length, 4 << 20) - pat.length;
  for (let i = 0x100000; i < end; i++) {
    let j = 0;
    while (j < pat.length && u8[i + j] === pat[j]) j++;
    if (j === pat.length) return i;
  }
  return 0;
}
const BREAKS = {
  T: { name: 'count of used units', write: (x) => x.break_table(15, 0) === 1 },
  C: {
    name: 'byte of the Roc literal "http://echo/f?id="',
    // poke_wait kind 4: XOR into the word at an address. "d" (0x64) of "id=" becomes "e".
    write: (x) => {
      const at = find(x, 'http://echo/f?id=');
      return at !== 0 && x.poke_wait(at + 15, 4, 0x01) === at + 15;
    },
  },
};

async function part(key, mode) {
  const b = BREAKS[key];
  const every = revert ? 0 : mode === 'every' ? 100 : 0;
  const whenIdle = revert ? false : mode === 'idle';
  const lines = [];
  let startedAtFail = -1;
  const r = makeRunner(module, io, {
    heapCheckEvery: every,
    heapCheckWhenIdle: whenIdle,
    log: (t) => {
      lines.push(t);
      if (/heap check failed/.test(t) && startedAtFail < 0) startedAtFail = r.tasks.stats.started;
    },
  });
  const x0 = r.x;
  let i = 0, startedAtBreak = -1, hit = false, failsBefore = 0, checksBefore = 0;
  const s = { goodOld: 0, badOld: 0, goodNew: 0, badNew: 0, other: 0 };
  // A Workers ctx: the runner gives it the promise of the idle check.
  let waitUntil = 0;
  const ctx = { waitUntil: (p) => { if (p instanceof Promise) waitUntil++; } };
  async function loop() {
    while (i < BEFORE + AFTER) {
      const n = i++;
      if (n === BEFORE) {
        failsBefore = r.stats.heapFails;
        checksBefore = r.stats.heapChecks;
        startedAtBreak = r.tasks.stats.started;
        hit = b.write(r.x);
      }
      const id = String(30000 + n);
      const onNew = r.x !== x0;
      const res = await r.run(`${id} 0 ${DEPTH} ${[5, 20, 400][n % 3]}`, { ctx });
      if (res.body === undefined) s.other++;
      else if (check(id, res.body, DEPTH)) onNew ? s.goodNew++ : s.goodOld++;
      else onNew ? s.badNew++ : s.badOld++;
    }
  }
  await Promise.all(Array.from({ length: LOOPS }, loop));
  const failsWhileRunning = r.stats.heapFails;
  await sleep(20);
  const after = await r.run(`7 0 ${DEPTH} 5`);
  const row = {
    key, mode, revert, hit, checksBefore, failsBefore, failsWhileRunning, fails: r.stats.heapFails,
    replaced: r.x !== x0, requestsToReplace: startedAtFail < 0 ? '-' : startedAtFail - startedAtBreak,
    byCheck: r.stats.byCheck, waitUntil, logLines: lines.length, ...s, next: check('7', after.body ?? '', DEPTH),
  };
  console.log(JSON.stringify(row));
  const tag = `${key} ${mode}`;
  if (!hit) fail(`${tag}: the write found no target: the test proves nothing`);
  if (failsBefore !== 0) fail(`${tag}: a check failed before the write`);
  if (mode === 'every' && !revert && checksBefore === 0) fail(`${tag}: no check before the write: the test proves nothing`);
  if (r.x === x0 || r.stats.heapFails !== 1) fail(`${tag}: the instance was not replaced (${r.stats.heapFails} failed checks)`);
  else if (mode === 'every' && !(startedAtFail - startedAtBreak <= 100)) fail(`${tag}: replaced after ${startedAtFail - startedAtBreak} requests, want at most 100`);
  if (mode === 'idle' && failsWhileRunning !== 0) fail(`${tag}: a check failed while requests ran (want only at idle)`);
  if (mode === 'idle' && r.stats.heapFails === 1 && !(r.stats.byCheck.idle > 0)) fail(`${tag}: the failed check was not an idle check`);
  if (mode === 'idle' && waitUntil === 0) fail(`${tag}: the idle check was not given to ctx.waitUntil`);
  if (lines.filter((t) => /heap check failed/.test(t)).length !== r.stats.heapFails) fail(`${tag}: log lines ${JSON.stringify(lines)}`);
  if (s.badNew !== 0 || !row.next) fail(`${tag}: ${s.badNew} wrong bodies on the new instance, next request ${row.next}`);
  if (key === 'C' && s.badOld === 0) fail(`${tag}: no wrong body after the write: the write proves nothing`);
  return row;
}

for (const key of ['T', 'C']) for (const mode of ['every', 'idle']) await part(key, mode);
console.log(failures.length ? `FAIL (${failures.length})` : 'PASS');
process.exit(failures.length ? 1 : 0);
