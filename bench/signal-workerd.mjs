// PLAN.md 3b, 3c in workerd: a client reset (TCP RST) aborts request.signal, and the task
// that waits is cancelled at once. 3.0: after a reset, the I/O of the request never settles.
// WORKERD=<path> node bench/signal-workerd.mjs
// 20 requests whose fetch answers after 10 min ("hang" ids). The client resets each socket
// after 300 ms. Expect: 20 cancels by the signal, 0 waiting tasks, live bytes 0, and good
// requests before and after are correct. Config: bench/config-s.capnp (the flag).
// Also (PLAN.md 5a): workerd registered the instance. It zeroes the CPU signal at registration,
// so the signal reads 0 (not 0xFFFF), and the terminated flag stays 0xFFFF.
import { spawn } from 'node:child_process';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './core.js';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8132';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const p = spawn(process.env.WORKERD, ['serve', join(here, 'config-s.capnp')], { stdio: ['ignore', 'ignore', 'inherit'] });
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) { await sleep(100); try { up = (await fetch(BASE + '/stats')).ok; } catch {} }
  if (!up) throw new Error('workerd did not start');
  const good = async (base) => {
    const ids = Array.from({ length: 20 }, (_, i) => String(base + i));
    const res = await Promise.all(ids.map(async (id) => { const r = await fetch(`${BASE}/h?id=${id}&depth=5`); return r.status === 200 && check(id, await r.text(), 5); }));
    return res.filter((ok) => !ok).length;
  };
  const bad1 = await good(1000);
  // Raw HTTP/1.1: the client resets the socket (RST) after 300 ms, as a client that goes away.
  const answered = [];
  await Promise.all(Array.from({ length: 20 }, (_, i) => new Promise((done) => {
    const s = net.connect(8132, '127.0.0.1', () => s.write(`GET /h?id=hang${i}&depth=5 HTTP/1.1\r\nHost: x\r\n\r\n`));
    s.on('data', () => answered.push(i));
    s.on('error', () => {});
    setTimeout(() => { s.resetAndDestroy(); done(); }, 300);
  })));
  await sleep(300);
  const st = await (await fetch(BASE + '/stats')).json();
  const bad2 = await good(2000);
  const st2 = await (await fetch(BASE + '/stats')).json();
  console.log({ bad1, answered: answered.length, cancels: st.cancels, cancelled: st.cancelled, waiting: st.waiting, live: st.live_bytes, traps: st.traps, retired: st.retired, bad2, liveEnd: st2.live_bytes, signal: st.signal, terminated: st.terminated });
  if (bad1 || bad2) fail('bad bodies');
  if (answered.length) fail('a hang request answered before the reset');
  if (st.cancels?.signal !== 20 || st.cancelled !== 20) fail('want 20 cancels by the signal');
  if (st.waiting !== 0 || st.live_bytes !== 0 || st2.live_bytes !== 0) fail('waiting tasks or live bytes not 0');
  if (st.traps !== 0 || st.retired !== 0) fail('a cancel counted as a trap');
  if (st.signal !== 0 || st.terminated !== 0xffff) fail(`5a: workerd did not register the instance (signal ${st.signal}, terminated ${st.terminated}; want 0 and 65535)`);
} finally {
  p.kill('SIGTERM');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
