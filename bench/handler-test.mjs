// PLAN.md 9a: `makeHandler(module, opts)` of js/index.js. No workerd.
// node bench/handler-test.mjs bench/out/app.wasm bench/out/app_prod.wasm
// 1. The handler class has `fetch`, and serves requests (200 at once, a trap gives a 500). Since 8b
//    `makeHandler` gives a class (a `WorkerEntrypoint` subclass): the test makes an instance with `(ctx, env)`.
// 2. An unknown option and a bad value throw at `makeHandler` time and name the option (8a: `io` is gone, so it is
//    an unknown option).
//    The options of the PLAN.md 4 table that are built accept good values.
// 3. `resumeCheck: "off"` on the production build throws at `makeHandler` time (no request) and names the bench host.
//    The bench build accepts it.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeHandler } from './cf-node.mjs';
import { check } from './check.js';
import { benchOps } from './ops.js';

const load = (f) => new WebAssembly.Module(readFileSync(f));
const bench = load(process.argv[2]);
const prod = load(process.argv[3]);
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  if (kind === 1) {
    await sleep(5);
    return 'f:' + new URL(b).searchParams.get('id');
  }
  await sleep(1);
  return 'd:' + a.split(' ')[1];
};
// The ops of bench/app.roc (bench/ops.js).
const ops = benchOps(io);
// The bench app reads the request text from the body (PLAN.md 8b, `bench/app.roc` `event!`).
const post = (text) => new Request('http://x/', { method: 'POST', body: text });
const throwsWith = (what, re, f) => {
  try {
    f();
  } catch (e) {
    if (!re.test(String(e))) fail(`${what}: the message does not match ${re}: ${e}`);
    return;
  }
  fail(`${what}: no throw`);
};

// 1
{
  const H = makeHandler(bench, { ops, isolateBytes: 2 ** 40 });
  const h = new H({}, {});
  if (typeof h.fetch !== 'function') fail('no fetch');
  const ids = Array.from({ length: 50 }, (_, i) => String(100 + i));
  const res = await Promise.all(ids.map((id) => h.fetch(post(`${id} 0 5`))));
  const bodies = await Promise.all(res.map((r) => r.text()));
  const bad = ids.filter((id, i) => res[i].status !== 200 || !check(id, bodies[i], 5)).length;
  const trapped = await h.fetch(post('999 1 5'));
  const tt = await trapped.text();
  const live = H.runner.x.live_bytes();
  console.log({ bad, trap: [trapped.status, tt.slice(0, 40)], live });
  if (bad) fail(`${bad} bad responses`);
  if (trapped.status !== 500 || !tt.startsWith('trap ')) fail(`a trap must give a 500 with "trap ..."`, trapped.status, tt);
  if (live !== 0) fail('live bytes are not 0');
}

// 2
const bad = {
  'an unknown option': [{ ops, nope: 1 }, /unknown option "nope"/],
  'other: a name of the class (8b)': [{ ops, other: ['fetch'] }, /"other"/],
  'other: not an array (8b)': [{ ops, other: 'queue' }, /"other"/],
  'other: a name twice (8b)': [{ ops, other: ['queue', 'queue'] }, /"other"/],
  'requestText (removed in 8b)': [{ ops, requestText: () => '' }, /unknown option "requestText"/],
  pinLimit: [{ ops, pinLimit: -1 }, /"pinLimit"/],
  'ops is not an object of functions': [{ ops: { f: 1 } }, /"ops"/],
  isolateBytes: [{ ops, isolateBytes: -1 }, /"isolateBytes"/],
  jsReserveBytes: [{ ops, jsReserveBytes: '48' }, /"jsReserveBytes"/],
  'reserve over isolate': [{ ops, isolateBytes: 2 ** 20, jsReserveBytes: 2 ** 21 }, /jsReserveBytes.*less than isolateBytes/],
  maxInstanceBytes: [{ ops, maxInstanceBytes: 0 }, /"maxInstanceBytes"/],
  growStepBytes: [{ ops, growStepBytes: 1.5 }, /"growStepBytes"/],
  graceMs: [{ ops, graceMs: -5 }, /"graceMs"/],
  // The fallback is removed (PLAN.md 1b): its options are unknown now.
  'queueLimit (removed 2026-10-16)': [{ ops, queueLimit: 5 }, /unknown option "queueLimit"/],
  'variant (removed 2026-10-16)': [{ ops, variant: 'b' }, /unknown option "variant"/],
  'noFallback (removed 2026-10-16)': [{ ops, noFallback: true }, /unknown option "noFallback"/],
  resumeCheck: [{ ops, resumeCheck: 'sometimes' }, /"resumeCheck".*"always"/],
  heapCheckEvery: [{ ops, heapCheckEvery: -1 }, /"heapCheckEvery"/],
  heapCheckWhenIdle: [{ ops, heapCheckWhenIdle: 'yes' }, /"heapCheckWhenIdle"/],
  taskDeadlineMs: [{ ops, taskDeadlineMs: 0 }, /"taskDeadlineMs"/],
  'io (removed in 8a)': [{ ops, io }, /unknown option "io"/],
  'opts is not an object': [5, /opts must be an object/],
};
for (const [what, [opts, re]] of Object.entries(bad)) throwsWith(what, re, () => makeHandler(bench, opts));
throwsWith('module is not a Module', /WebAssembly.Module/, () => makeHandler({}, { ops }));
const good = { isolateBytes: 2 ** 40, jsReserveBytes: 0, maxInstanceBytes: Infinity, growStepBytes: 65536, graceMs: 0, resumeCheck: 'afterAlarm', heapCheckEvery: 0, heapCheckWhenIdle: false, taskDeadlineMs: 1000, pinLimit: 10, ops: { ...ops, f: () => 1 } };
const G = makeHandler(bench, { ...good, other: ['queue', 'email'] });
const gr = await new G({}, {}).fetch(post('7 0 5'));
if (gr.status !== 200 || !check('7', await gr.text(), 5)) fail('a handler with all options set gave a bad response');
console.log('options: bad values throw at makeHandler time, good ones are accepted');

// 3
throwsWith('resumeCheck "off" on the production build', /resumeCheck "off".*bench host/, () => makeHandler(prod, { ops, resumeCheck: 'off' }));
const Off = makeHandler(bench, { ops, resumeCheck: 'off', isolateBytes: 2 ** 40 });
const or = await new Off({}, {}).fetch(post('8 0 5'));
if (or.status !== 200 || !check('8', await or.text(), 5)) fail('the bench build with resumeCheck "off" gave a bad response');
console.log('resumeCheck "off": the production build throws at makeHandler time, the bench build serves');

console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
