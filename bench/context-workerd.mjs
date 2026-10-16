// PLAN.md 9b in workerd: the context of a task. WORKERD=<path> node bench/context-workerd.mjs
// 40 requests at once (variant a too: the queue of 4f holds the requests the budget does not fit; PLAN.md "Fallback queue in workerd") to bench/worker.js, each with its own header `x-ctx-id`. The effect of the bench app
// (`io` in worker.js) gets the task id, reads the request of that task from the task table, and sends its header
// to the echo service, which answers with it. The body is right only when each effect saw the headers of its
// own request. Config bench/config-a.capnp (variant a) and bench/config-b.capnp (variant b), both on port 8131.
// Exit 1 on a failure.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './check.js';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8131';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
for (const [variant, config, n] of [['a', 'config-a.capnp', 40], ['b', 'config-b.capnp', 40]]) {
  const p = spawn(process.env.WORKERD, ['serve', join(here, config)], { stdio: ['ignore', 'ignore', 'inherit'] });
  try {
    let up = false;
    for (let i = 0; i < 100 && !up; i++) {
      await sleep(100);
      try {
        up = (await fetch(BASE + '/stats')).ok;
      } catch {}
    }
    if (!up) throw new Error('workerd did not start');
    for (const round of [0, 1]) {
      const ids = Array.from({ length: n }, (_, i) => `c${round}-${i}`);
      const res = await Promise.all(
        ids.map(async (id) => {
          const r = await fetch(`${BASE}/h?id=${id}&depth=5`, { headers: { 'x-ctx-id': id } });
          return { status: r.status, body: await r.text() };
        }),
      );
      const bad = ids.filter((id, i) => res[i].status !== 200 || !check(id, res[i].body, 5));
      console.log(variant, { round, bad: bad.length, first: bad[0] && res[ids.indexOf(bad[0])].body.slice(-50) });
      if (bad.length) fail(`${variant}: ${bad.length} of ${n} requests got the headers of another request`);
    }
    const st = await (await fetch(BASE + '/stats')).json();
    if (st.variant !== variant || st.served !== 2 * n) fail(`${variant}: stats`, st.variant, st.served);
  } catch (e) {
    fail(String(e));
  } finally {
    p.kill('SIGTERM');
    await once(p, 'exit');
  }
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
