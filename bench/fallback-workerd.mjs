// PLAN.md "Fallback queue in workerd": variant a (one instance for each request) with the default budget options.
// WORKERD=<path> node bench/fallback-workerd.mjs [--rounds=3] [--n=40] [--items=<n>] [--rss]
// 40 requests at once, 3 rounds, to bench/worker.js with config-a.capnp (port 8131). Each request must give the
// right body. workerd logs "hung" when the code of the Worker waits on nothing that is I/O: that is a failure too.
// With --rss: print the RSS of the workerd process and the budget counters after each round (the memory check).
// Exit 1 on a failed request or a "hung" log line.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './check.js';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8131';
const arg = (k, d) => Number((process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `=${d}`).split('=')[1]);
const rounds = arg('rounds', 3);
const n = arg('n', 40);
const items = arg('items', 0);
const showRss = process.argv.includes('--rss');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const rssMB = (pid) => {
  const m = /VmRSS:\s+(\d+) kB/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'));
  return m ? +(Number(m[1]) / 1024).toFixed(1) : null;
};
const p = spawn(process.env.WORKERD, ['serve', join(here, 'config-a.capnp')], { stdio: ['ignore', 'ignore', 'pipe'] });
let err = '';
p.stderr.on('data', (d) => {
  err += d;
  if (process.argv.includes('--verbose')) process.stderr.write(d);
});
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) {
    await sleep(100);
    try {
      up = (await fetch(BASE + '/stats')).ok;
    } catch {}
  }
  if (!up) throw new Error('workerd did not start');
  for (let round = 0; round < rounds; round++) {
    const ids = Array.from({ length: n }, (_, i) => `f${round}-${i}`);
    const t0 = Date.now();
    const res = await Promise.all(
      ids.map(async (id) => {
        try {
          const r = await fetch(`${BASE}/h?id=${id}&depth=5${items ? `&items=${items}` : ''}`, { signal: AbortSignal.timeout(30_000) });
          return { status: r.status, body: await r.text() };
        } catch (e) {
          return { status: 0, body: String(e) };
        }
      }),
    );
    const bad = ids.filter((id, i) => res[i].status !== 200 || !check(id, res[i].body, 5));
    let line = { round, ms: Date.now() - t0, bad: bad.length, first: bad[0] && res[ids.indexOf(bad[0])].status + ' ' + res[ids.indexOf(bad[0])].body.slice(0, 80) };
    if (showRss || bad.length) {
      try {
        const st = await (await fetch(BASE + '/stats')).json();
        const b = st.budget ?? {};
        line = { ...line, rssMB: rssMB(p.pid), totalMB: +(b.total / 2 ** 20).toFixed(1), droppedMB: +(b.dropped / 2 ** 20).toFixed(1), droppedCount: b.droppedCount, collected: b.collected, maxTotalMB: +(b.maxTotal / 2 ** 20).toFixed(1), queued: st.queued, queueNow: st.queueNow, liveCount: st.liveCount, shedMem: st.shedMem };
      } catch {}
    }
    console.log(line);
    if (bad.length) fail(`${bad.length} of ${n} requests failed in round ${round}`);
  }
} catch (e) {
  fail(String(e));
} finally {
  p.kill('SIGTERM');
  const kill = setTimeout(() => p.kill('SIGKILL'), 5000);
  await once(p, 'exit');
  clearTimeout(kill);
}
const hung = err.split('\n').filter((l) => /hung/i.test(l));
if (hung.length) fail(`workerd logged "hung" ${hung.length} times:`, hung[0].slice(0, 200));
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
