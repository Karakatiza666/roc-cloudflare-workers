// PLAN.md 8a: the tests of the bridge, with bench/app_bridge.roc in Node (bench/bridge-workerd.mjs: the main ones in
// workerd). node bench/bridge-test.mjs bench/out/app_bridge.wasm [only]   (only: a test name, for a revert check)
// Each test sends one request "<case> <args>" and checks the body, the time and the waits of the task
// (`task_waits`). The ops of the app are the fakes below (API.md 6.4: the root `ops`).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const only = process.argv[3];
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
// A wait of `ms`. An abort before the end rejects it and is counted in `aborts` (with the text of its reason).
const sleep = (ms, signal) =>
  new Promise((res, rej) => {
    const onAbort = () => {
      clearTimeout(t);
      aborts.push(`${ms}: ${signal.reason?.message}`);
      rej(signal.reason);
    };
    const t = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      res(ms);
    }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
let aborts = [];
let r = null;
class Thing {}
const t1 = new Thing(), t2 = new Thing();
let startedDone = 0;
const ops = {
  // As a D1 binding: an object with methods (a function, so the shim option `ops` takes it).
  db: Object.assign(() => {}, { prepare: (sql) => ({ bind: (...a) => ({ raw: async () => [[sql, ...a]] }) }) }),
  thing: () => t1,
  other: () => t2,
  sleep: async (ms, signal) => {
    const v = await sleep(ms, signal);
    startedDone++;
    return v;
  },
  name: (n) => 'name-' + n,
  rows: (n) => Array.from({ length: n }, (_, i) => ({ id: i, name: 'pkg-' + i, version: '1.' + i })),
  batch: () => [{ results: [{ id: 1, name: 'a', version: 'v' }], meta: { changes: 0 } }, { results: [], meta: { changes: 2 } }],
  messages: () => [{ id: 'a', body: 1 }, { id: 'b', body: 2 }],
  objs: (n) => Array.from({ length: n }, () => new Thing()),
  tick: (s) => sleep(1, s),
  hang: () => new Promise(() => {}),
  // The result block of this wait gets no memory (`js_alloc` gives 0): status 4.
  failAlloc: async () => {
    await sleep(1);
    r.x.fail_next_alloc();
    return 'x';
  },
};
const logs = [];
// The log lines of the shim and of the app.
r = makeRunner(module, null, { ops, isolateBytes: 2 ** 40, log: (t) => logs.push(t), onLog: (level, t) => logs.push(t) });

// One request: the body (or the trap), the time and the waits of the task.
async function run(req, ro) {
  const w0 = r.x.task_waits();
  const t0 = performance.now();
  const res = await r.run(req, ro);
  return { ...res, ms: performance.now() - t0, waits: r.x.task_waits() - w0 };
}
const show = (x) => x.body ?? `trap ${x.status ?? ''} ${x.cause ?? x.alarm ?? ''} ${x.trap}`;
const tests = [];
const test = (name, f) => tests.push([name, f]);
const expectBody = (name, x, want) => {
  const ok = want instanceof RegExp ? want.test(x.body ?? '') : x.body === want;
  if (!ok) fail(`${name}: got ${show(x)}, want ${want}`);
  return ok;
};

test('refs', async () => {
  // RS1: two refs of one JS object in a task are equal, refs of two objects are not.
  const x = await run('refs');
  expectBody('refs', x, 'same=true other=false');
  return show(x);
});
test('four', async () => {
  // A program of 4 ops gives the value of the last op, with one wait.
  const x = await run('four');
  expectBody('four', x, 'ok [["select ?",7]]');
  if (x.waits !== 1) fail(`four: ${x.waits} waits, want 1`);
  return `${show(x)}, ${x.waits} wait`;
});
test('promise', async () => {
  // OP1: a promise in `call!` is status 2 (the error PromiseInCall).
  const x = await run('promise');
  expectBody('promise', x, /^err PromiseInCall: /);
  return show(x);
});
test('both', async () => {
  // OP6: `Io.both!` of two waits of 100 ms: one wait, about 100 ms.
  const x = await run('both 100');
  expectBody('both', x, 'ok 100 100');
  if (x.waits !== 1) fail(`both: ${x.waits} waits, want 1`);
  if (x.ms < 95 || x.ms > 180) fail(`both: ${x.ms.toFixed(0)} ms, want about 100`);
  return `${show(x)}, ${x.waits} wait, ${x.ms.toFixed(0)} ms`;
});
test('bothsync', async () => {
  // OP6: `Io.both!` of two `Io.sync` values gives Ok (a Par runs with await!).
  const x = await run('bothsync');
  expectBody('bothsync', x, 'ok "name-a" "name-b"');
  return show(x);
});
test('oom', async () => {
  // API.md 4.1: `js_alloc` fails during a wait: status 4, a clean OOM trap. The instance stays.
  const x0 = r.x, alarms = r.stats.alarms;
  const x = await run('op failAlloc');
  if (x.status !== 503 || x.cause !== 'oom') fail(`oom: got ${show(x)}, want 503 oom`);
  if (r.x !== x0 || r.stats.alarms !== alarms) fail('oom: the trap was not clean (an alarm, or the instance was replaced)');
  if (r.x.live_bytes() !== 0) fail(`oom: live bytes ${r.x.live_bytes()}`);
  const next = await run('four');
  expectBody('oom: next request', next, 'ok [["select ?",7]]');
  return show(x);
});
test('null', async () => {
  // OP7: Get and Fields on null and undefined give undefined. Call on null is status 1.
  const x = await run('null');
  expectBody('null', x, /^get=ok undefined getu=ok undefined fields=ok undefined fieldsu=ok undefined call=err TypeError: /);
  return show(x);
});
test('race', async () => {
  // OP8: the first to settle wins (index 0 after about 50 ms), one wait, the other branch sees its abort (the abort of
  // the race, not the one at the end of the task).
  aborts = [];
  const x = await run('race 50 500');
  expectBody('race', x, 'index=0 ok 50');
  if (x.waits !== 1) fail(`race: ${x.waits} waits, want 1`);
  if (x.ms < 45 || x.ms > 200) fail(`race: ${x.ms.toFixed(0)} ms, want about 50`);
  await sleep(5);
  if (aborts.join() !== '500: the branch lost the race') fail(`race: the aborted branches are [${aborts}], want [500: the branch lost the race]`);
  return `${show(x)}, ${x.waits} wait, ${x.ms.toFixed(0)} ms, aborted [${aborts}]`;
});
test('race0', async () => {
  // OP8: a Race with no branch is status 3 (a bad program): `Io` crashes, a clean trap of the task (no body, no
  // alarm). The host does not log the crash text (hostlib/roc.zig LOG_CRASH is off), so the test sees the trap only.
  const alarms = r.stats.alarms;
  const x = await run('race0');
  if (x.body !== undefined || x.status !== undefined || r.stats.alarms !== alarms) fail(`race0: got ${show(x)}, want a clean trap`);
  const one = await run('race 1 1');
  expectBody('race0: a race of 2 branches', one, /^index=[01] ok 1$/);
  return show(x);
});
test('packeach', async () => {
  // API.md 6.4: `pf.packEach` gives each item with its field as Packed (Cbor.parse reads it), the other fields stay.
  const x = await run('packeach');
  expectBody('packeach', x, 'items=2 rows=1 ids=1 last=a v meta={changes:0}; rows=0 ids=0 last=- meta={changes:2}');
  return show(x);
});
test('find', async () => {
  // API.md 6.4: `pf.findById` gives the item of the id, and undefined for an unknown id.
  const b = await run('find b');
  const z = await run('find z');
  expectBody('find b', b, 'ok {id:"b",body:2}');
  expectBody('find z', z, 'ok undefined');
  return `${show(b)} | ${show(z)}`;
});
test('pack', async () => {
  // API.md 5.2: a Packed value of 200 rows reaches Roc as one List(U8), and Cbor.parse reads it.
  const x = await run('pack 200');
  expectBody('pack', x, 'packed rows=200 ids=19900 last=pkg-199 1.199');
  return show(x);
});
test('pin', async () => {
  // RS2: a CryptoKey that one task pins is used by a later task.
  const a = await run('pin k1');
  const b = await run('use k1');
  expectBody('pin', a, 'ok undefined');
  expectBody('use', b, 'ok [bytes:32,true,{type:"secret",extractable:false}]');
  return `${show(a)} | ${show(b)}`;
});
test('hd3', async () => {
  // HD3: Roc fixtures to JS and back, compared in Roc with ==.
  const x = await run('hd3');
  // A Packed value to JS is the value of its bytes (API.md 5: `Js` to JS), so it comes back as [1,2].
  expectBody('hd3', x, 'hd3 true 29  packed=ok [[1,2]]');
  return show(x);
});
test('hd6', async () => {
  // HD6: 1,000 decodes of the fixtures in one task, each value dropped: no live bytes after, and the host freed
  // nothing at the end of the task (`leaked_at_end`: a leak in a task goes back with its pages, so live bytes alone
  // do not show it).
  const leaked0 = r.x.leaked_at_end();
  const x = await run('hd6 1000');
  const leaked = r.x.leaked_at_end() - leaked0;
  expectBody('hd6', x, 'hd6 1000');
  if (r.x.live_bytes() !== 0 || leaked !== 0) fail(`hd6: live bytes ${r.x.live_bytes()}, leaked at the end of the task ${leaked}`);
  return `${show(x)}, live bytes ${r.x.live_bytes()}, leaked at the end ${leaked}`;
});
test('start', async () => {
  // API.md 6.5: a started program runs after its task, with the context of the task, which goes after it.
  const done = startedDone;
  const x = await run('start 30');
  expectBody('start', x, 'started');
  const live = r.tasks.stats.contextsLive;
  await sleep(60);
  if (startedDone !== done + 1) fail('start: the started program did not run to its end');
  if (live !== 1 || r.tasks.stats.contextsLive !== 0) fail(`start: contexts live ${live} at the response (want 1), ${r.tasks.stats.contextsLive} after (want 0)`);
  return `${show(x)}, contexts live ${live} then ${r.tasks.stats.contextsLive}`;
});
test('refs10k', async () => {
  // 10c: 10,000 tasks with refs, some trap, some are cancelled while they wait: the ref table is empty after.
  let ok = 0, traps = 0, cancels = 0, other = 0;
  for (let round = 0; round < 100; round++) {
    const batch = Array.from({ length: 100 }, (_, i) => {
      const mode = i % 10 === 3 ? 'trap' : i % 10 === 7 ? 'hang' : 'ok';
      const ac = new AbortController();
      if (mode === 'hang') setTimeout(() => ac.abort(), 5);
      return r.run(`objs ${mode} 5`, { signal: ac.signal }).then((x) => {
        if (x.body === 'objs 5') ok++;
        else if (x.cancelled) cancels++;
        else if (x.trap && x.status === undefined) traps++;
        else other++;
      });
    });
    await Promise.all(batch);
  }
  const s = r.tasks.stats;
  const row = { ok, traps, cancels, other, refsLive: s.refsLive, contextsLive: s.contextsLive, live: r.x.live_bytes() };
  if (ok !== 8000 || traps !== 1000 || cancels !== 1000 || other) fail(`refs10k: ${JSON.stringify(row)}`);
  if (s.refsLive !== 0 || s.contextsLive !== 0) fail(`refs10k: the ref table is not empty: ${JSON.stringify(row)}`);
  return JSON.stringify(row);
});

for (const [name, f] of tests) {
  if (only && name !== only) continue;
  try {
    console.log(`${name}: ${await f()}`);
  } catch (e) {
    fail(`${name}: threw ${e?.stack ?? e}`);
  }
}
if (!only && r.x.live_bytes() !== 0) fail(`live bytes at the end: ${r.x.live_bytes()}`);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
