// PLAN.md 4a (M1): one instance per isolate. node bench/oneinstance-test.mjs bench/out/app.wasm
// 1,000 requests, 25 at a time, with waits. Each 100th request makes an unclean trap: a forced
// out-of-bounds write at its first wait (`fault_next_wait`, V2). After 12c an unclean trap is an
// alarm: the task gets a 503, `task_abort` gives -1 and frees its pages and slot, the alarm counter
// of the host goes up, and the global check runs. It passes (the write hit nothing), so the
// instance stays and the other tasks of the wave finish on it.
// Expect: never more than 1 instance with a task, 0 bad bodies, 10 alarms "trap" (host counter
// +10), 10 passed checks, 0 replaces, 0 cancels, every other request a good body, the table empty.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const N = 1000, WAVE = 25;

// One shared instance.
{
  let maxLive = 0;
  let r = null;
  const sample = () => { maxLive = Math.max(maxLive, r.tasks.liveInstances()); };
  const io = async (kind, a, b) => {
    sample();
    await sleep(1 + (kind === 1 ? 3 : 0));
    return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
  };
  r = makeRunner(module, io);
  const victims = new Set();
  const all = [];
  const x0 = r.x;
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
    // Let the trap handler run (the alarm) while the other tasks of the wave still wait.
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
    } else if (res.cancelled) cancels++;
    else if (victim && res.alarm === 'trap' && res.status === 503) ownTraps++;
    else { other++; if (other < 4) console.log('OTHER', id, res.trap); }
  }
  const st = r.stats;
  const hostAlarms = x0.alarms();
  console.log({ ok, bad, ownTraps, cancels, other, maxLive, retired: st.retired, walkFailed: st.walkFailed, hostAlarms, alarmChecks: st.byCheck.alarm, heapFails: st.heapFails, table: r.tasks.size });
  if (maxLive > 1) fail(`${maxLive} instances with tasks at one time`);
  if (bad !== 0) fail(`${bad} bad bodies`);
  if (other !== 0) fail(`${other} requests ended in another way`);
  if (ownTraps !== victims.size) fail(`${ownTraps} own traps, want ${victims.size}`);
  if (st.retired !== 0 || r.x !== x0) fail(`${st.retired} replaces, want 0 (an alarm must not replace the instance)`);
  if (st.walkFailed !== victims.size) fail(`${st.walkFailed} unclean traps, want ${victims.size}`);
  if (hostAlarms !== victims.size) fail(`the alarm counter of the host is ${hostAlarms}, want ${victims.size}`);
  if (st.byCheck.alarm !== victims.size || st.heapFails !== 0) fail(`${st.byCheck.alarm} checks after an alarm, ${st.heapFails} failed, want ${victims.size} and 0`);
  if (cancels !== 0) fail(`${cancels} tasks cancelled, want 0`);
  if (ok + bad + ownTraps + cancels + other !== N) fail('a request is missing');
  if (r.tasks.size !== 0) fail(`${r.tasks.size} tasks left in the table`);
  const live = r.x.live_bytes();
  if (live !== 0) fail(`live bytes ${live} at the end`);
  const last = await r.run('7 0 5 10');
  if (!check('7', last.body ?? '', 5)) fail('the last request is wrong');
}

console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
