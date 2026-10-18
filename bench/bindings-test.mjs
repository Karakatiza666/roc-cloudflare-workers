// Step 8h wave B issue 5 (MODULES.md 3): `Worker.new bindings` and `crons` in Node (the stand-in of bench/cf-node.mjs).
// node bench/bindings-test.mjs bench/out
//   app_b3.wasm        fetch, class Counter, bindings DB (d1), KV (kv), COUNTERS (object), cron "*/5 * * * *", no scheduled!
//   app_b3_dup.wasm    two bindings named DB: the load fails
//   app_b3_class.wasm  a namespace of the class Ghost that is not in objects: the load fails
//   app_events.wasm    no bindings, no crons: loads as before
// The same checks in workerd (missing binding, wrong kind) are in conformance/checks/bindings.mjs, and the cron order with a
// scheduled! is in conformance/checks/cron.mjs.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { makeHandler, objectClass } from './cf-node.mjs';

const dir = process.argv[2] ?? 'bench/out';
const load = (f) => new WebAssembly.Module(readFileSync(`${dir}/${f}`));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const lines = [];
const opts = { log: (text) => lines.push(text) };

const fns = (...names) => Object.fromEntries(names.map((n) => [n, () => {}]));
const good = () => ({ DB: fns('prepare', 'batch'), KV: fns('get', 'put', 'getWithMetadata'), COUNTERS: fns('idFromName', 'newUniqueId') });
const get = (H, env) => new H({ waitUntil() {} }, env).fetch(new Request('http://x/'));
const throws = async (name, re, f) => {
  try {
    await f();
  } catch (e) {
    if (re.test(String(e.message))) return pass(name, String(e.message).split('\n').slice(0, 2).join(' | ').slice(0, 160));
    return fail(`${name}: the message does not match ${re}: ${e.message}`);
  }
  fail(`${name}: no throw`);
};

// The class exports of objectClass are global to the process and app_events has no class: check 5 runs in its own process.
if (process.argv[3] === 'plain') {
  // 5. An app with no bindings and no crons loads as before, and checks nothing of env.
  {
    const H = makeHandler(load('app_events.wasm'), { other: ['ping'], ...opts });
    const r = await get(H, {});
    if (r.status === 200 || r.status === 404) pass(`5 no bindings: loads, serves ${r.status}`);
    else fail(`5: status ${r.status}`);
  }
  process.exit(failed ? 1 : 0);
}

objectClass('Counter');
const b3 = makeHandler(load('app_b3.wasm'), opts);

// 1. All bindings there with their kind: the app serves.
{
  const r = await get(b3, good());
  const text = await r.text();
  if (r.status === 200 && text === 'b3') pass('1 all bindings there: 200 b3');
  else fail(`1: ${r.status} ${text}`);
}
// 2. A missing binding, a wrong kind (d1 vs kv, kv vs d1), a namespace of another shape.
{
  const noDb = good();
  delete noDb.DB;
  await throws('2a no DB in env', /DB \(d1\): env has no DB.*\[\[d1_databases\]\]/s, () => get(b3, noDb));
  await throws('2b DB is a KV namespace', /DB \(d1\): env\.DB is not a D1 database \(it has no prepare\)/, () => get(b3, { ...good(), DB: fns('get', 'put', 'getWithMetadata') }));
  await throws('2c KV is a D1 database', /KV \(kv\): env\.KV is not a KV namespace/, () => get(b3, { ...good(), KV: fns('prepare', 'batch') }));
  await throws('2d COUNTERS is not a namespace', /COUNTERS \(object\): env\.COUNTERS is not a Durable Object namespace/, () => get(b3, { ...good(), COUNTERS: fns('get') }));
  await throws('2e a null binding', /KV \(kv\): env has no KV/, () => get(b3, { ...good(), KV: null }));
  await throws('2f all missing: each is in the message', /DB \(d1\).*KV \(kv\).*COUNTERS \(object\)/s, () => get(b3, {}));
}
// 3. The manifest errors are at load, with no request.
await throws('3a a binding name twice', /binding DB is twice in Worker\.new bindings/, () => makeHandler(load('app_b3_dup.wasm'), opts));
await throws('3b a namespace class that is not in objects', /namespace GHOSTS has the class Ghost.*Object\.class\("Ghost".*script/s, () => makeHandler(load('app_b3_class.wasm'), opts));
// 4. A cron: the handler of Worker.cron (it fails with FromCron), any other cron with no scheduled!: unhandled.
{
  const ctl = (cron) => ({ cron, scheduledTime: 1_700_000_000_000, noRetry() {} });
  const sched = (cron) => new b3({ waitUntil() {} }, good()).scheduled(ctl(cron));
  await throws('4a the cron of Worker.cron runs its handler', /scheduled: failed: FromCron/, () => sched('*/5 * * * *'));
  await throws('4b another cron, no scheduled!: unhandled', /scheduled: unhandled/, () => sched('0 0 * * *'));
}
const plain = spawnSync(process.execPath, [process.argv[1], dir, 'plain'], { stdio: 'inherit' });
process.exit(failed || plain.status !== 0 ? 1 : 0);
