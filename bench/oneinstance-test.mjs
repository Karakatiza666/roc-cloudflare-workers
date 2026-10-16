// PLAN.md 4a (M1): one instance per isolate. node bench/oneinstance-test.mjs bench/out/app.wasm
// 1,000 requests, 25 at a time, with waits. Each 100th request makes an unclean trap: a forced
// out-of-bounds write at its first wait (`fault_next_wait`, V2). The runner replaces the instance
// and cancels the tasks of the old one (3c), so tasks never wait on two instances.
// Expect: never more than 1 instance with a task, 0 bad bodies, 10 replaces, every request ends
// with a good body, its own trap, or a 503 cancel (`replace`), the table is empty at the end.
// Then variant a (the fallback of problem 1): 1,000 requests with 1 % clean traps, 0 bad bodies.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const N = 1000, WAVE = 25;

// 1. Variant b: one shared instance. (A module that is not stack-first falls back to variant a: skipped.)
{
  let maxLive = 0;
  let r = null;
  const sample = () => { maxLive = Math.max(maxLive, r.tasks.liveInstances()); };
  const io = async (kind, a, b) => {
    sample();
    await sleep(1 + (kind === 1 ? 3 : 0));
    return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
  };
  r = makeRunner(module, 'b', io);
  if (r.stats.fallback) console.log('b: the module is not stack-first, the runner uses an instance per request: part 1 skipped');
  else {
    const victims = new Set();
    const all = [];
    for (let i = 0; i < N; i++) {
      const id = String(10000 + i);
      const victim = i % 100 === 60;
      if (victim) {
        victims.add(id);
        // The fault hits the first wait of the next `run`, which starts its task in this call.
        r.x.fault_next_wait(1);
      }
      all.push(r.run(`${id} 0 8 10`).then((res) => ({ id, victim, res })));
      sample();
      // Let the trap handler run (the replace) while the other tasks of the wave still wait.
      if (victim) await sleep(0);
      if (i % WAVE === WAVE - 1) await sleep(3);
    }
    const done = await Promise.all(all);
    let bad = 0, ok = 0, ownTraps = 0, cancels = 0, other = 0;
    for (const { id, victim, res } of done) {
      if (res.body !== undefined) {
        if (victim) fail(`victim ${id} got a body`);
        else if (check(id, res.body, 8)) ok++;
        else { bad++; if (bad < 4) console.log('BAD', id, res.body); }
      } else if (res.cancelled === 'replace') cancels++;
      else if (victim) ownTraps++;
      else { other++; if (other < 4) console.log('OTHER', id, res.trap); }
    }
    const st = r.stats;
    console.log('b', { ok, bad, ownTraps, cancels, other, maxLive, retired: st.retired, walkFailed: st.walkFailed, table: r.tasks.size });
    if (maxLive > 1) fail(`b: ${maxLive} instances with tasks at one time`);
    if (bad !== 0) fail(`b: ${bad} bad bodies`);
    if (other !== 0) fail(`b: ${other} requests ended in another way`);
    if (ownTraps !== victims.size) fail(`b: ${ownTraps} own traps, want ${victims.size}`);
    if (st.retired !== victims.size) fail(`b: ${st.retired} replaces, want ${victims.size}`);
    if (st.walkFailed !== victims.size) fail(`b: ${st.walkFailed} unclean traps, want ${victims.size}`);
    if (cancels === 0) fail('b: no task was cancelled by a replace: the test proves nothing');
    if (ok + bad + ownTraps + cancels + other !== N) fail('b: a request is missing');
    if (r.tasks.size !== 0) fail(`b: ${r.tasks.size} tasks left in the table`);
    const live = r.x.live_bytes();
    if (live !== 0) fail(`b: live bytes ${live} at the end`);
    const last = await r.run('7 0 5 10');
    if (!check('7', last.body ?? '', 5)) fail('b: the last request is wrong');
  }
}

// 2. Variant a (an instance per request): 1 % clean traps (a Roc crash). No replace, no pool.
{
  const io = async (kind, a, b) => {
    await sleep(1);
    return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
  };
  const r = makeRunner(module, 'a', io);
  const all = [];
  for (let i = 0; i < N; i++) {
    const id = String(20000 + i);
    all.push(r.run(`${id} ${i % 100 === 50 ? 1 : 0} 8 10`).then((res) => ({ id, res })));
    if (i % WAVE === WAVE - 1) await sleep(8);
  }
  let bad = 0, traps = 0;
  for (const { id, res } of await Promise.all(all)) {
    if (res.body === undefined) traps++;
    else if (!check(id, res.body, 8)) bad++;
  }
  console.log('a', { bad, traps, retired: r.stats.retired, table: r.tasks.size });
  if (bad !== 0) fail(`a: ${bad} bad bodies`);
  if (traps !== N / 100) fail(`a: ${traps} traps, want ${N / 100}`);
  if (r.tasks.size !== 0) fail(`a: ${r.tasks.size} tasks left in the table`);
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
