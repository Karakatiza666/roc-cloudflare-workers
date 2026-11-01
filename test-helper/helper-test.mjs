// The tests of the test helper (research/design-notes/test-helper.md 7: H1 to H7, H9 to H11) with `js/test.mjs` and two apps on
// the production host: examples/hello and test-helper/app (H2). One line for each check: `PASS <name>` or `FAIL <name>: <why>`.
//   node test-helper/helper-test.mjs <hello.wasm> <helper.wasm> [name-filter]
// Env: MINIFLARE (else the global wrangler of this node). The bench host is not used (Q8).
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startApp, findMiniflare, TEST_API, splitSql, answerOf } from '../js/test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const helloWasm = resolve(process.argv[2] || join(root, '.cache/th/hello.wasm'));
const helperWasm = resolve(process.argv[3] || join(root, '.cache/th/helper.wasm'));
const filter = process.argv[4];
const T0 = 1767225600000;
let failed = 0;
let passed = 0;
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const eq = (got, want, what = 'value') => {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};
const ok = (cond, why) => {
  if (!cond) throw new Error(why);
};
const text = async (app, path, init) => (await app.fetch(path, init)).text();
const helper = (o = {}) => startApp({ dir: join(here, 'app'), shim: '../../js', wasm: helperWasm, now: T0, d1: { DB: ['CREATE TABLE items (v TEXT); INSERT INTO items (v) VALUES (\'seed\')'] }, ...o });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
// Poll until `fn()` is true (a queue delivery, an alarm).
const until = async (fn, ms = 5000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await fn()) return true;
    await wait(25);
  }
  return false;
};
const baseTmp = tmpdir(); // before startApp sets TMPDIR
const runDirs = () => readdirSync(baseTmp).filter((f) => f.startsWith(`cfw-test-${process.pid}`));

// TH13.
test('TH13: TEST_API is test of cfw.json', async () => {
  eq(TEST_API, JSON.parse(readFileSync(join(root, 'js/cfw.json'), 'utf8')).test, 'TEST_API');
});

// H1: examples/hello.
test('H1: examples/hello: start, fetch, D1 seed and read, close; no run dir, no .wrangler/', async () => {
  const dir = join(root, 'examples/hello');
  const hadWrangler = existsSync(join(dir, '.wrangler'));
  const app = await startApp({ dir, shim: '../../js', wasm: helloWasm, d1: { DB: ['CREATE TABLE people (id INTEGER, name TEXT); INSERT INTO people VALUES (1, \'ann\')'] } });
  try {
    eq(await text(app, '/'), 'hello from Roc', '/');
    eq(await text(app, '/d1'), 'Ok [{ avatar: [1, 2, 3], id: 1, name: "ann" }]', '/d1');
    const db = await app.d1('DB');
    eq((await db.prepare('SELECT name FROM people').all()).results, [{ name: 'ann' }], 'the seeded row');
    ok(existsSync(app.runDir) && app.runDir.startsWith(baseTmp), 'no run dir while the app runs');
  } finally {
    await app.close();
  }
  ok(!existsSync(app.runDir), 'the run dir is there after close');
  ok(hadWrangler || !existsSync(join(dir, '.wrangler')), 'a .wrangler/ dir is in examples/hello');
});

// TH1.
test('TH1: a seed of a binding that the app does not declare is a throw with the name', async () => {
  const e = await helper({ kv: { NOPE: { a: 'b' } } }).then((a) => (a.close(), 'no throw'), (x) => x.message);
  ok(/NOPE/.test(e) && /does not declare/.test(e), e);
  const e2 = await helper({ d1: { KV: ['SELECT 1'] } }).then((a) => (a.close(), 'no throw'), (x) => x.message);
  ok(/declares as kv/.test(e2), e2);
});
test('TH1: no shim is a throw that names roc-cfw sync', async () => {
  const e = await startApp({ dir: join(here, 'app'), wasm: helperWasm }).then((a) => (a.close(), 'no throw'), (x) => x.message);
  ok(/roc-cfw sync/.test(e), e);
});

let app;
// H3: the defaults of app.fetch (T1, T2, T8), and the header strip (O1).
test('H3 T1: a text body arrives with no Content-Type', async () => {
  eq(await text(app, '/echo', { method: 'POST', body: 'hi' }), 'POST ct=- cc=- pragma=- body=hi');
});
test('H3 T2: a request with If-None-Match arrives with no Cache-Control and no Pragma', async () => {
  eq(await text(app, '/echo', { headers: { 'if-none-match': '"abc"' } }), 'GET ct=- cc=- pragma=- body=');
});
test('H3 T8: a 302 of the app is seen (redirect manual)', async () => {
  const r = await app.fetch('/redirect');
  eq([r.status, r.headers.get('location')], [302, '/']);
});
test('H3 O1: the app does not see the header cfw-test-request', async () => {
  eq(await text(app, '/header?name=cfw-test-request'), 'none');
});
test('H3: the caller can give its own headers and content type', async () => {
  eq(await text(app, '/echo', { method: 'PUT', body: '{}', headers: { 'content-type': 'application/json' } }), 'PUT ct=application/json cc=- pragma=- body={}');
});

// H4: the clock.
test('H4: now at start, setNow, init.now, advance', async () => {
  eq(await text(app, '/now'), String(T0), 'at start');
  await app.setNow(T0 + 5000);
  eq(await text(app, '/now'), String(T0 + 5000), 'after setNow');
  eq(await text(app, '/now', { now: T0 + 7000 }), String(T0 + 7000), 'init.now');
  await app.advance(1000);
  eq(await text(app, '/now'), String(T0 + 8000), 'after advance');
  await app.setNow(null);
  const real = Number(await text(app, '/now'));
  ok(Math.abs(real - Date.now()) < 5000, `setNow(null): ${real} is not the real clock`);
  await app.setNow(T0);
});
test('H4: advance(61_000) expires a Memo of 60 s; advance(30_000) does not', async () => {
  const a = await text(app, '/memo');
  await app.advance(30_000);
  eq(await text(app, '/memo'), a, 'after 30 s');
  await app.advance(31_000);
  ok((await text(app, '/memo')) !== a, 'the Memo did not load again after 61 s');
});
test('H4: scheduled and queue see the set time', async () => {
  const r = await app.scheduled({ cron: '*/5 * * * *', time: T0 + 1, now: T0 + 100 });
  eq(r.outcome, 'ok', 'outcome');
  eq(await (await app.kv('KV')).get('cron'), `${T0 + 1} ${T0 + 100}`, 'the cron key');
  const q = await app.queue('jobs', [{ body: { n: 5 } }], { now: T0 + 200 });
  eq(q.outcome, 'ok', 'queue outcome');
  eq(await (await app.kv('KV')).get('job-5'), String(T0 + 200), 'the job key');
});

// H5: counts (TH4, TH6, TH16).
test('H5: 1 batch and 2 all give n 3; prepare and bind give 0', async () => {
  const r = await app.fetch('/d1/three');
  eq([r.calls.DB.n, r.calls.DB.ops], [3, ['batch', 'all', 'all']]);
  const r2 = await app.fetch('/d1/count');
  eq([r2.calls.DB.n, r2.calls.DB.ops], [1, ['first']], '/d1/count');
});
test('H5 TH16: the session of each call, and res.sessions', async () => {
  const r = await app.fetch('/d1/session?b=bookmark-1');
  eq(r.calls.DB.list.map((c) => [c.op, c.session]), [['all', 'bookmark-1']]);
  eq(r.sessions, { DB: ['bookmark-1'] }, 'sessions');
  const r2 = await app.fetch('/d1/count');
  eq(r2.calls.DB.list.map((c) => c.session), [null], 'no session');
});
test('H5 TH4: Response.after work and an object alarm go to app.calls(), not to res.calls', async () => {
  await app.calls({ reset: true });
  const r = await app.fetch('/after?k=after-1');
  eq(await r.text(), 'early');
  eq(r.calls.KV.n, 0, 'res.calls.KV of the after request');
  await app.idle();
  const r2 = await app.fetch('/room/alarm?name=a1');
  eq(r2.calls.KV.n, 0, 'res.calls.KV of the alarm request');
  ok(await until(async () => (await (await app.kv('KV')).get('alarm')) === 'rang'), 'the alarm did not run');
  await app.idle();
  const all = await app.calls({ reset: true });
  eq(all.KV.list.map((c) => `${c.op} ${c.kind} ${c.name}`), ['put Fetch fetch', 'put Alarm Room.alarm'], 'app.calls().KV');
  eq((await app.calls()).KV.n, 0, 'after reset');
});

test('H5 TH4: two requests at the same time: each res.calls has the calls of its own request only', async () => {
  const slow = app.fetch('/slow?ms=400');
  await wait(100);
  const fast = await app.fetch('/kv/put?k=concurrent&v=1');
  const s = await slow;
  eq(await s.text(), 'Ok { n: 1 }', 'slow');
  eq([s.calls.DB.n, s.calls.KV.n], [1, 0], 'the slow request');
  eq([fast.calls.DB.n, fast.calls.KV.n], [0, 1], 'the fast request');
});

// H6 (S6): wrapEnv reaches each kind (hooks module, TH7).
test('H6: the hooks module sees Fetch, Scheduled, Queue, Init, Rpc, Alarm', async () => {
  const a = await helper({ hooks: 'tests/hooks.js', count: ['KV'] });
  try {
    await a.fetch('/now');
    await a.scheduled({ cron: '*/5 * * * *' });
    await a.queue('jobs', [{ body: { n: 1 } }]);
    eq(await text(a, '/room/bump?name=h6'), 'Ok 1', 'bump');
    await a.fetch('/room/alarm?name=h6');
    ok(await until(async () => (await (await a.kv('KV')).get('alarm')) === 'rang'), 'the alarm did not run');
    await a.idle();
    const kinds = JSON.parse(await text(a, '/__kinds'));
    for (const k of ['Fetch', 'Scheduled', 'Queue', 'Init', 'Rpc', 'Alarm']) ok(kinds[k] >= 1, `no ${k}: ${JSON.stringify(kinds)}`);
    // TH7: hooks.fetch answers with a local import; its env is the counted one; its log line is in app.logs.
    const r = await a.fetch('/__hook');
    eq([await r.text(), r.calls.KV.n], ['hook local-import', 1], 'the hook route');
    ok(a.logs.some((l) => JSON.stringify(l).includes('hook log local-import')), `app.logs has no hook line: ${JSON.stringify(a.logs).slice(0, 300)}`);
  } finally {
    await a.close();
  }
});

// H2: a queue message through the local queue reaches the consumer.
test('H2: a producer message reaches the queue consumer of the app', async () => {
  eq(await text(app, '/send?n=9'), 'Ok {}');
  ok(await until(async () => (await (await app.kv('KV')).get('job-9')) !== null), 'the consumer did not run');
});

// H11 and the outbound answers (TH18).
test('H11: 3 requests to a key with 2 answers give answer 1, 2, 2; count 3; a request with no key is in unmatched', async () => {
  const k = 'GET https://api.test/a';
  const a = await helper({ outbound: { [k]: [{ status: 200, body: 'one' }, { status: 201, body: 'two!' }] } });
  try {
    const got = [];
    for (let i = 0; i < 3; i++) got.push(await text(a, '/out?url=https://api.test/a'));
    eq(got, ['status=200 len=3 cl=3', 'status=201 len=4 cl=4', 'status=201 len=4 cl=4'], 'answers');
    ok((await text(a, '/out?url=https://api.test/none')).startsWith('status=599 '), 'no key: not 599');
    const o = a.outbound();
    eq([o.count[k], o.log.length, o.unmatched], [3, 4, ['GET https://api.test/none']], 'outbound()');
  } finally {
    await a.close();
  }
});
test('TH18: an answer body gets a Content-Length; chunked: true has none and sends each byte', async () => {
  const big = 'x'.repeat(100_000);
  const a = await helper({ outbound: { 'GET https://api.test/len': [{ body: big }], 'GET https://api.test/chunked': [{ body: big, chunked: true }], 'GET https://api.test/fn': () => new Response('fn'), 'GET https://api.test/lie': [{ body: 'abcdef', headers: { 'content-length': '3' } }] } });
  const f = await helper({ outbound: (req) => (req.url.endsWith('/c') ? { body: 'abc', chunked: true } : new Response('fn2')) });
  try {
    eq(await text(a, '/out?url=https://api.test/len'), 'status=200 len=100000 cl=100000', 'default');
    eq(await text(a, '/out?url=https://api.test/chunked'), 'status=200 len=100000 cl=none', 'chunked');
    eq(await text(a, '/out?url=https://api.test/fn'), 'status=200 len=2 cl=2', 'a Response of a function in the table');
    // Talon slice 111: workerd frames the body by the Content-Length, so a smaller value cuts the body.
    eq(await text(a, '/out?url=https://api.test/lie'), 'status=200 len=3 cl=3', 'a Content-Length that is too small cuts the body');
    eq(await text(f, '/out?url=https://api.test/x'), 'status=200 len=3 cl=3', 'a Response of the outbound function');
    eq(await text(f, '/out?url=https://api.test/c'), 'status=200 len=3 cl=none', 'an answer object of the outbound function, chunked');
  } finally {
    await a.close();
    await f.close();
  }
});
test('TH18: a size limit test needs chunked: the limit of the app stops a chunked body', async () => {
  const big = 'y'.repeat(50_000);
  const a = await helper({ outbound: { 'GET https://api.test/chunked': [{ body: big, chunked: true }], 'GET https://api.test/len': [{ body: big }] } });
  try {
    ok((await text(a, '/out_max?url=https://api.test/chunked&max=1000')).includes('TooLarge'), 'chunked: no TooLarge');
    eq(await text(a, '/out_max?url=https://api.test/chunked&max=60000'), 'len=50000', 'chunked under the limit');
    ok((await text(a, '/out_max?url=https://api.test/len&max=1000')).includes('TooLarge'), 'with a length: no TooLarge');
  } finally {
    await a.close();
  }
});
test('TH18: answerOf: a lying Content-Length of the caller stays (the caller decides)', async () => {
  const r = await answerOf({ body: 'abc', headers: { 'content-length': '3' } });
  eq(r.headers.get('content-length'), '3');
  const c = await answerOf({ body: 'abc', chunked: true, headers: { 'content-length': '3' } });
  eq([c.headers.get('content-length'), await c.text()], [null, 'abc'], 'chunked drops it');
});

// H9 (S5): reset.
test('H9: after writes to D1, KV, R2, the Cache API (default and named), a Memo and the clock, reset gives the start state', async () => {
  const a = await helper({ kv: { KV: { seeded: 'yes' } }, r2: { BUCKET: { 'r/seed': 'seed' } } });
  try {
    const memo0 = await text(a, '/memo');
    await text(a, '/d1/add?v=w');
    await text(a, '/kv/put?k=w&v=1');
    await text(a, '/r2/put?k=w&v=1');
    await text(a, '/cache/put?url=https://c.test/a&v=d');
    await text(a, '/cache/put?url=https://c.test/a&name=n1&v=n');
    await text(a, '/after?k=late');
    await a.setNow(T0 + 999_999);
    eq([await text(a, '/d1/count'), await text(a, '/cache/get?url=https://c.test/a'), await text(a, '/cache/get?url=https://c.test/a&name=n1')], ['Ok { n: 2 }', 'Ok d', 'Ok n'], 'before reset');
    await a.reset();
    eq(await text(a, '/d1/count'), 'Ok { n: 1 }', 'D1');
    eq(await text(a, '/kv/get?k=w'), 'Err NotFound', 'KV write');
    eq(await text(a, '/kv/get?k=late'), 'Err NotFound', 'KV after work');
    eq(await text(a, '/kv/get?k=seeded'), 'Ok "yes"', 'KV seed');
    eq(await text(a, '/r2/get?k=w'), 'Err NotFound', 'R2 write');
    eq(await text(a, '/r2/get?k=r/seed'), 'Ok seed', 'R2 seed');
    eq(await text(a, '/cache/get?url=https://c.test/a'), 'Err NotFound', 'cache default');
    eq(await text(a, '/cache/get?url=https://c.test/a&name=n1'), 'Err NotFound', 'cache named');
    eq(await text(a, '/now'), String(T0), 'clock');
    ok((await text(a, '/memo')) !== memo0, 'the Memo did not load again');
    eq((await a.calls()).DB, undefined, 'calls');
  } finally {
    await a.close();
  }
});

// H10: the time of reset against a new startApp (no fail limit).
test('H10: 20 resets against 20 starts (time printed)', async () => {
  const opts = { d1: { DB: ['CREATE TABLE items (v TEXT); CREATE INDEX iv ON items (v); INSERT INTO items (v) VALUES (\'seed\')'] } };
  let t = performance.now();
  for (let i = 0; i < 20; i++) {
    const a = await helper(opts);
    await text(a, '/d1/add?v=x');
    await a.close();
  }
  const starts = performance.now() - t;
  const a = await helper(opts);
  t = performance.now();
  for (let i = 0; i < 20; i++) {
    await text(a, '/d1/add?v=x');
    await a.reset();
  }
  const resets = performance.now() - t;
  eq(await text(a, '/d1/count'), 'Ok { n: 1 }', 'after 20 resets');
  await a.close();
  return `20 starts ${starts.toFixed(0)} ms (${(starts / 20).toFixed(0)} ms each), 20 resets ${resets.toFixed(0)} ms (${(resets / 20).toFixed(0)} ms each)`;
});

// Two apps in one process: each has its own run dir (TH9).
test('TH9: two apps at once; the close of the first does not break the second', async () => {
  const a = await helper();
  const b = await helper();
  try {
    ok(a.runDir !== b.runDir, 'one run dir');
    await a.close();
    eq(await text(b, '/d1/count'), 'Ok { n: 1 }', 'the second app');
    ok(existsSync(b.runDir), 'the run dir of the second app is gone');
  } finally {
    await a.close();
    await b.close();
  }
});

// H7: Miniflare discovery (TH10).
test('H7: MINIFLARE, a local node_modules/miniflare, the global wrangler, none', async () => {
  const global = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
  const fromEnv = findMiniflare({ dir: tmpdir(), env: { MINIFLARE: global }, execPath: '/nowhere/bin/node' });
  ok(typeof fromEnv.Miniflare === 'function', 'MINIFLARE');
  const proj = join(root, '.cache/th/discovery');
  rmSync(proj, { recursive: true, force: true });
  mkdirSync(join(proj, 'node_modules'), { recursive: true });
  symlinkSync(global, join(proj, 'node_modules/miniflare'));
  ok(typeof findMiniflare({ dir: proj, env: {}, execPath: '/nowhere/bin/node' }).Miniflare === 'function', 'local node_modules');
  ok(typeof findMiniflare({ dir: tmpdir(), env: {} }).Miniflare === 'function', 'global wrangler');
  let e = 'no throw';
  try {
    findMiniflare({ dir: tmpdir(), env: {}, execPath: '/nowhere/bin/node' });
  } catch (x) {
    e = x.message;
  }
  ok(/npm i -D wrangler/.test(e) && e.includes('/nowhere/lib/node_modules/wrangler/node_modules/miniflare') && e.includes('miniflare (from'), e);
  rmSync(proj, { recursive: true, force: true });
});

// TH19: the split rules.
test('TH19: splitSql keeps a trigger body, quotes and comments', async () => {
  eq(splitSql("CREATE TRIGGER t AFTER INSERT ON a BEGIN UPDATE b SET n = n + 1; END; -- c;\nINSERT INTO a VALUES ('x;y'); /* ; */ SELECT 1"), ["CREATE TRIGGER t AFTER INSERT ON a BEGIN UPDATE b SET n = n + 1; END", "INSERT INTO a VALUES ('x;y')", 'SELECT 1']);
});
test('TH19: app.sql runs statements between requests', async () => {
  await app.sql('DB', ["INSERT INTO items (v) VALUES ('s1'); INSERT INTO items (v) VALUES ('s2')"]);
  eq(await text(app, '/d1/count'), 'Ok { n: 3 }');
  await app.sql('DB', ["DELETE FROM items WHERE v LIKE 's%' AND v != 'seed'"]);
});

// Run.
app = await helper({ count: ['DB', 'KV'] });
try {
  for (const [name, fn] of tests) {
    if (filter && !name.includes(filter)) continue;
    try {
      const detail = await fn();
      passed++;
      console.log(`PASS ${name}${detail ? `: ${detail}` : ''}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e.message}`);
    }
  }
} finally {
  await app.close();
}
const left = runDirs();
if (left.length) {
  failed++;
  console.log(`FAIL run dirs left: ${left.join(', ')}`);
}
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
