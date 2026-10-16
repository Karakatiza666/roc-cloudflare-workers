// PLAN.md 4e in workerd: a dropped instance counts in the budget until the FinalizationRegistry callback.
// WORKERD=<path> node bench/budget-workerd.mjs
// Config bench/config-m.capnp: variant b, isolateBytes 64 MB, jsReserveBytes 0, graceMs 0.
// 1. A request holds 30 MB: the instance is 32 MB.
// 2. /replace drops the instance (M1). The budget shows 32 MB of dropped instance.
// 3. A request that holds 40 MB gets a 503 (32 + 2 + 40 is over 64 MB). Both instances together stay at or under 64 MB.
// 4. Load (64 requests at once, again and again) until the callback reports the old instance collected
//    (3.0: 5.5 s under load). The budget shows 32 MB until then.
// 5. The same request now passes.
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './core.js';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8133';
const MB = 2 ** 20;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const p = spawn(process.env.WORKERD, ['serve', join(here, 'config-m.capnp')], { stdio: ['ignore', 'ignore', 'inherit'] });
const stats = async () => (await fetch(BASE + '/stats')).json();
let seq = 0;
const req = async (mb) => {
  const id = `m${seq++}`;
  const r = await fetch(`${BASE}/h?id=${id}&depth=5${mb ? `&mb=${mb}` : ''}`);
  const body = await r.text();
  return { status: r.status, ok: r.status === 200 && check(id, body, 5), body: body.slice(0, 80) };
};
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) { await sleep(100); try { up = (await fetch(BASE + '/stats')).ok; } catch {} }
  if (!up) throw new Error('workerd did not start');
  const warm = await req(0);
  const first = await req(30);
  const s1 = await stats();
  const rep = await (await fetch(BASE + '/replace')).json();
  const s2 = await stats();
  const during = await req(40);
  const s3 = await stats();
  console.log({ warm: warm.ok, first: first.ok, memMB: +(s1.mem / MB).toFixed(1), droppedAfterReplaceMB: +(rep.dropped / MB).toFixed(1), totalMB: +(s2.budget.total / MB).toFixed(1), during: [during.status, during.body], newMemMB: +(s3.mem / MB).toFixed(1), denied: s3.budget.denied });
  if (!warm.ok || !first.ok) fail('the first requests failed', warm, first);
  if (s1.mem < 30 * MB) fail('the instance did not grow to 30 MB');
  if (rep.dropped < 30 * MB || s2.budget.dropped !== rep.dropped || s2.budget.droppedCount !== 1) fail('the budget does not show the dropped instance', rep, s2.budget);
  if (s3.budget.denied < 1) fail('no denied grow was counted');
  if (during.status !== 503) fail('the request of 40 MB must get a 503 while the old instance is not collected:', during);
  if (rep.dropped + s3.mem > 64 * MB) fail('the two instances went over 64 MB:', rep.dropped + s3.mem);
  // Load until the callback.
  const t0 = Date.now();
  let st = s3, rounds = 0, samples = 0, shown = 0;
  while (st.budget.droppedCount > 0 && Date.now() - t0 < 90_000) {
    const res = await Promise.all(Array.from({ length: 64 }, () => req(0)));
    if (res.some((x) => !x.ok)) fail('a good request failed under load');
    st = await stats();
    rounds++;
    // The budget shows the dropped instance in every sample until the callback.
    samples++;
    if (st.budget.droppedCount > 0 && st.budget.dropped === rep.dropped) shown++;
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log({ collected: st.budget.droppedCount === 0, afterSec: secs, rounds, samples, shownWhileNotCollected: shown });
  if (st.budget.droppedCount !== 0) fail('the callback did not report the old instance collected in 90 s');
  if (shown !== samples - 1 && shown !== samples) fail('the budget did not show the dropped instance until the callback', { shown, samples });
  const after = await req(40);
  const s4 = await stats();
  console.log({ after: [after.status, after.ok], totalMB: +(s4.budget.total / MB).toFixed(1), live: s4.live_bytes });
  if (!after.ok) fail('after the callback the request of 40 MB must pass:', after);
  if (s4.budget.total > 64 * MB) fail('the budget went over 64 MB');
} catch (e) {
  fail(String(e));
} finally {
  p.kill('SIGTERM');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
