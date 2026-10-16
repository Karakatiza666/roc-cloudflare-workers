// PLAN.md 8a in workerd: the main tests of bench/bridge-test.mjs, with bench/app_bridge.wasm in bench/bridge-worker.js
// (config bench/config-bridge.capnp, port 8134). WORKERD=<path> node bench/bridge-workerd.mjs
// The worker gives the waits of each task (header x-waits) and its time (x-ms). The pin test signs with a real
// CryptoKey of workerd. 300 tasks with refs (some trap, some are cancelled: the client resets the socket while the task
// waits) leave the ref table empty.
// Exit 1 on a failure.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const BASE = 'http://127.0.0.1:8134';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const get = async (q, signal) => {
  const r = await fetch(`${BASE}/b?q=${encodeURIComponent(q)}`, { signal });
  return { status: r.status, body: await r.text(), waits: Number(r.headers.get('x-waits')), ms: Number(r.headers.get('x-ms')) };
};
const json = async (path) => (await fetch(BASE + path)).json();
// A client that goes away: raw HTTP/1.1, and a reset of the socket (RST) after `ms` (as bench/signal-workerd.mjs).
const resetAfter = (q, ms) =>
  new Promise((done) => {
    const s = net.connect(8134, '127.0.0.1', () => s.write(`GET /b?q=${encodeURIComponent(q)} HTTP/1.1\r\nHost: x\r\n\r\n`));
    s.on('error', () => {});
    setTimeout(() => {
      s.resetAndDestroy();
      done();
    }, ms);
  });
const expect = (name, x, want) => {
  const ok = want instanceof RegExp ? want.test(x.body) : x.body === want;
  if (!ok) fail(`${name}: got ${x.status} ${x.body}, want ${want}`);
  console.log(`${name}: ${x.body.slice(0, 100)} (${x.waits} waits, ${x.ms} ms)`);
};

const p = spawn(process.env.WORKERD, ['serve', join(here, 'config-bridge.capnp')], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
p.stderr.on('data', (d) => (stderr += d));
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) {
    await sleep(100);
    try {
      up = (await fetch(BASE + '/stats')).ok;
    } catch {}
  }
  if (!up) throw new Error('workerd did not start');
  expect('refs', await get('refs'), 'same=true other=false');
  const four = await get('four');
  expect('four', four, 'ok [["select ?",7]]');
  if (four.waits !== 1) fail(`four: ${four.waits} waits`);
  expect('promise', await get('promise'), /^err PromiseInCall: /);
  const both = await get('both 100');
  expect('both', both, 'ok 100 100');
  if (both.waits !== 1 || both.ms < 95 || both.ms > 180) fail(`both: ${both.waits} waits, ${both.ms} ms`);
  expect('bothsync', await get('bothsync'), 'ok "name-a" "name-b"');
  await json('/aborts');
  const race = await get('race 50 500');
  expect('race', race, 'index=0 ok 50');
  if (race.waits !== 1 || race.ms < 45 || race.ms > 200) fail(`race: ${race.waits} waits, ${race.ms} ms`);
  const aborts = await json('/aborts');
  if (aborts.join() !== '500: the branch lost the race') fail(`race: aborts ${aborts}`);
  expect('null', await get('null'), /^get=ok undefined getu=ok undefined fields=ok undefined fieldsu=ok undefined call=err TypeError: /);
  expect('pin', await get('pin k1'), 'ok undefined');
  expect('use (a later task)', await get('use k1'), 'ok [bytes:32,true,{type:"secret",extractable:false}]');
  expect('pack', await get('pack 200'), 'packed rows=200 ids=19900 last=pkg-199 1.199');
  expect('find', await get('find b'), 'ok {id:"b",body:2}');
  expect('hd3', await get('hd3'), 'hd3 true 29  packed=ok [[1,2]]');
  const oom = await get('op failAlloc');
  if (oom.status !== 503 || !/oom/.test(oom.body)) fail(`oom: ${oom.status} ${oom.body}`);
  console.log(`oom: ${oom.status} ${oom.body}`);
  // 10c: tasks with refs that end, trap, or are cancelled (the client goes away while the task waits).
  let ok = 0, traps = 0, cancels = 0;
  for (let round = 0; round < 6; round++) {
    await Promise.all(
      Array.from({ length: 50 }, async (_, i) => {
        const mode = i % 10 === 3 ? 'trap' : i % 10 === 7 ? 'hang' : 'ok';
        if (mode === 'hang') {
          await resetAfter(`objs ${mode} 5`, 50);
          cancels++;
          return;
        }
        const x = await get(`objs ${mode} 5`);
        if (x.body === 'objs 5') ok++;
        else if (x.status === 503) traps++;
      }),
    );
  }
  await sleep(200);
  const st = await json('/stats');
  console.log('refs', { ok, traps, cancels, ...st });
  if (ok !== 240 || traps !== 30 || cancels !== 30) fail(`refs: ok ${ok}, traps ${traps}, cancels ${cancels}`);
  if (st.refsLive !== 0 || st.contextsLive !== 0 || st.live !== 0 || st.alarms !== 0) fail(`refs: the ref table is not empty or memory is live: ${JSON.stringify(st)}`);
} catch (e) {
  fail(String(e));
} finally {
  p.kill('SIGTERM');
  await once(p, 'exit');
}
if (failed) console.log('workerd stderr (end):', stderr.slice(-1500));
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
