// PLAN.md 8b (first half), in workerd: bench/app_events.wasm behind `makeHandler` (bench/events-worker.js), with an
// entry service (bench/entry-worker.js) that serves the scheduled path of Miniflare. Config: bench/config-entry.capnp,
// port 8135. `--experimental`: the flag `service_binding_extra_handlers` needs it (Miniflare sets it too).
// WORKERD=<path> node bench/entry-workerd.mjs
// 1. A binary body (0x00 to 0xFF) round trip, 100 headers, status 404.
// 2. `GET /cdn-cgi/local/scheduled?cron=*/5+*+*+*+*&time=1700000000000&format=json` reaches `scheduled!` with that
//    cron and `time_ms`, and answers the outcome `ok`. `Err`: not `ok` (500) and `noRetry: false`. `no_retry!` then
//    `Err`: `noRetry: true`. No `scheduled!`: not `ok` and `noRetry: false`.
// 3. A queue event (`queue` in the option `other`) reaches `Other`: the outcome `ok`.
// 4. `Unhandled`: a 500 and a log line. `Err`: a 500 and a log line with the error. A `crash`: its text in the log line.
// Exit 1 on a failure.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8135';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const log = async () => (await fetch(BASE + '/__log')).json();

const p = spawn(process.env.WORKERD, ['serve', '--experimental', join(here, 'config-entry.capnp')], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
p.stderr.on('data', (d) => (stderr += d));
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) {
    await sleep(100);
    try {
      up = (await fetch(BASE + '/__log')).ok;
    } catch {}
  }
  if (!up) throw new Error(`workerd did not start: ${stderr.slice(-400)}`);

  // 1
  {
    const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
    const res = await fetch(BASE + '/echo', { method: 'POST', body: bytes });
    const got = new Uint8Array(await res.arrayBuffer());
    const same = got.length === 256 && got.every((b, i) => b === i);
    console.log('1 binary body:', res.status, got.length, same);
    if (res.status !== 200 || !same) fail(`1: binary body: status ${res.status}, ${got.length} bytes, same ${same}`);
    const headers = {};
    for (let i = 0; i < 100; i++) headers[`x-h-${i}`] = `v${i}-${'z'.repeat(i)}`;
    const h = await fetch(BASE + '/headers', { headers });
    const back = [...h.headers].filter(([k]) => k.startsWith('x-h-'));
    const sameH = back.length === 100 && back.every(([k, v]) => headers[k] === v);
    console.log('1 headers:', h.status, back.length, sameH);
    if (h.status !== 200 || !sameH) fail(`1: ${back.length} headers came back`);
    const m = await fetch(BASE + '/missing');
    console.log('1 status:', m.status);
    if (m.status !== 404) fail(`1: status ${m.status}, want 404`);
  }

  // 2
  const scheduled = async (cron) => {
    const r = await fetch(`${BASE}/cdn-cgi/local/scheduled?cron=${encodeURIComponent(cron).replace(/%20/g, '+')}&time=1700000000000&format=json`);
    return { status: r.status, ...(await r.json()), log: (await log()).join(' | ') };
  };
  for (const [name, cron, ok, noRetry, line] of [
    ['2a cron and time_ms', '*/5 * * * *', true, false, null],
    ['2b Err', 'fail', false, false, /scheduled: failed: Failing/],
    ['2c no_retry! then Err', 'noretry', false, true, /scheduled: failed: Failing/],
    ['2d no scheduled!', 'none', false, false, /scheduled: unhandled/],
  ]) {
    const r = await scheduled(cron);
    console.log(name, r);
    if ((r.outcome === 'ok') !== ok || r.status !== (ok ? 200 : 500) || r.noRetry !== noRetry) fail(`${name}: ${JSON.stringify(r)}`);
    if (line && !line.test(r.log)) fail(`${name}: no log line with ${line}`);
  }

  // 3
  {
    const r = await (await fetch(BASE + '/queue')).json();
    const l = (await log()).join(' | ');
    console.log('3 queue:', r, l);
    if (r.outcome !== 'ok') fail(`3: queue gave ${JSON.stringify(r)} ${l}`);
  }

  // 4
  for (const [name, path, line] of [
    ['4a unhandled', '/unhandled', /^fetch: unhandled/],
    ['4b err', '/err', /^fetch: failed: Boom\(42\)$/],
    ['4c crash', '/crash', /^fetch: trap: the crash text of app_events$/],
  ]) {
    const r = await fetch(BASE + path);
    const body = await r.text();
    const l = (await log()).join(' | ');
    console.log(name, r.status, JSON.stringify(body.slice(0, 40)), l);
    if (r.status !== 500 || !line.test(l)) fail(`${name}: ${r.status} ${l}`);
  }
} catch (e) {
  fail(String(e));
} finally {
  p.kill();
  await once(p, 'exit');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
