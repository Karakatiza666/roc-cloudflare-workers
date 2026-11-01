// `on_trap` (MODULES.md 3, design note research/design-notes/trap-response.md, rules TR1 to TR12), in Node.
// node bench/trap-test.mjs [dir with the wasm files]    (default: bench/out)
//   1 (T2)  checkTraps: the limits of TR5 and TR6, each a throw that names the field; the values at the limit pass.
//   2 (TR2) causeOf: the cause of each runner result.
//   3 (TR1, TR7) trapResponse with no table: the response of 0.0.2, plus retry-after on shed and oom (O2).
//   4 (T3, T4, T6, T7) app_trap.wasm behind makeHandler: the entry of each cause, a new body for each response, the
//     retry-after rules, the fetch of an object class and of an entry point, Response.after and pass_through!.
//   5 (T5) no export of the instance is read and no handle runs between the trap and the response.
//   6 (T8, TR1, O2) app_trap_none.wasm (no on_trap): the responses of 0.0.2; an OOM and a shed have retry-after.
// `cloudflare:workers` is the stand-in of bench/cf-workers-stub.mjs (bench/cf-node.mjs). Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { checkManifest, checkTraps, causeOf, trapResponse, TRAP_CAUSES } from '../js/manifest.js';
import { MB } from '../js/budget.js';
import { manifestOf } from '../js/runner.js';
import { manifestEvent } from '../js/events.js';

// 5 (T5): each read of an export of an instance (a function, `memory`) and each call of a `handle` while `armed` counts.
// The patch is in place before the shim makes its first instance.
const reads = [];
let armed = false;
const RealInstance = WebAssembly.Instance;
WebAssembly.Instance = function (module, imports) {
  const inst = new RealInstance(module, imports);
  return { exports: new Proxy(inst.exports, { get: (t, k) => (armed && reads.push(String(k)), t[k]) }) };
};
const realPromising = WebAssembly.promising;
WebAssembly.promising = (f) => {
  const p = realPromising(f);
  return (...a) => (armed && reads.push('handle (promising)'), p(...a));
};
const { makeHandler, objectClass, entrypointClass } = await import('./cf-node.mjs');

const dir = resolve(process.argv[2] ?? join(fileURLToPath(new URL('..', import.meta.url)), 'bench/out'));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const check = (name, cond, why) => (cond ? pass(name) : fail(`${name}: ${why}`));
const throws = (name, re, f) => {
  try {
    f();
  } catch (e) {
    return check(name, re.test(String(e.message)), `the message does not match ${re}: ${e.message}`);
  }
  fail(`${name}: no throw`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const wasm = (f) => new WebAssembly.Module(readFileSync(join(dir, f)));
const env = {};
const ctx = { waitUntil() {} };
// A body that cannot be read (a body stream that an earlier response used) is the text `<error: ...>`.
const read = async (res) => ({ status: res.status, headers: Object.fromEntries(res.headers), body: await res.text().catch((e) => `<error: ${e.message}>`) });

// ---- 1 (T2): checkTraps ----
{
  const entry = (o = {}) => ({ status: 500, headers: [], body: new Uint8Array(0), ...o });
  const one = (o) => checkTraps({ default: entry(o) });
  const hs = (n) => Array.from({ length: n }, (_, i) => [`x-h-${i}`, 'v']);
  throws('1a status 200 is refused, the field is named', /on_trap\.default\.status: the status 200 is not 400 to 599/, () => one({ status: 200 }));
  throws('1b status 600 is refused', /on_trap\.default\.status: the status 600/, () => one({ status: 600 }));
  throws('1c status 399 is refused', /status 399/, () => one({ status: 399 }));
  check('1d status 400 and 599 pass (O6)', one({ status: 400 }).default.status === 400 && one({ status: 599 }).default.status === 599, '');
  // TR5: a body of 4,096 bytes passes, 4,097 bytes is a throw (revert check S2: off by one).
  throws('1e a body of 4,097 bytes is refused', /on_trap\.default\.body: 4097 bytes, the limit is 4096/, () => one({ body: new Uint8Array(4097) }));
  check('1f a body of 4,096 bytes passes', one({ body: new Uint8Array(4096) }).default.body.length === 4096, '');
  throws('1g 17 headers are refused', /on_trap\.default\.headers: 17 headers, the limit is 16/, () => one({ headers: hs(17) }));
  check('1h 16 headers pass', one({ headers: hs(16) }).default.headers.length === 16, '');
  throws('1i a value with CR LF is refused', /on_trap\.default\.headers\[0\]\.value: the value of x-a has a CR, an LF or a NUL/, () => one({ headers: [['x-a', 'a\r\nb: c']] }));
  throws('1j a value with NUL is refused', /CR, an LF or a NUL/, () => one({ headers: [['x-a', 'a\0']] }));
  throws('1k a value of 1,025 bytes is refused', /1025 bytes, the limit is 1024/, () => one({ headers: [['x-a', 'v'.repeat(1025)]] }));
  check('1l a value of 1,024 bytes passes', one({ headers: [['x-a', 'v'.repeat(1024)]] }).default.headers[0][1].length === 1024, '');
  throws('1m a name that is not a token is refused', /on_trap\.default\.headers\[0\]\.name: "x a" is not an HTTP token/, () => one({ headers: [['x a', 'v']] }));
  for (const n of ['content-length', 'Transfer-Encoding', 'connection', 'upgrade', 'keep-alive', 'Set-Cookie']) throws(`1n the header ${n} is refused (TR6)`, new RegExp(`the header ${n} cannot be in a fixed response`), () => one({ headers: [[n, '1']] }));
  check('1o any content-type passes, also application/problem+json', one({ headers: [['content-type', 'application/problem+json']] }).default.headers[0][1] === 'application/problem+json', '');
  throws('1p a table with no default is refused', /on_trap\.default: the field default is missing/, () => checkTraps({ crash: entry() }));
  throws('1q an unknown cause is refused', /on_trap\.boom: the cause is not one of/, () => checkTraps({ default: entry(), boom: entry() }));
  throws('1r a body that is not bytes is refused', /on_trap\.crash\.body: the body is not bytes/, () => checkTraps({ default: entry(), crash: entry({ body: 'text' }) }));
  const body = new Uint8Array([1, 2, 3]);
  const t = checkTraps({ default: entry({ body }) });
  check('1s the checked body is a copy (no other code has a reference to it)', t.default.body !== body && t.default.body.join() === '1,2,3', '');
  check('1t checkManifest: no traps key gives traps null (TR1)', checkManifest({}).traps === null, '');
  check('1u checkManifest: a table gives the checked table', checkManifest({ traps: { default: entry() } }).traps.default.status === 500, '');
  throws('1v checkManifest checks the table', /on_trap\.default\.status/, () => checkManifest({ traps: { default: entry({ status: 302 }) } }));
}

// ---- 2 (TR2): causeOf ----
{
  const rows = [
    [{ trap: 'RuntimeError: unreachable', crash: 'boom' }, 'crash'],
    [{ trap: 'RangeError: Maximum call stack size exceeded' }, 'crash'],
    [{ trap: 'RuntimeError: unreachable', status: 503, alarm: 'trap' }, 'alarm'],
    [{ trap: 'alarm: sum', status: 503, alarm: 'sum' }, 'alarm'],
    [{ trap: 'cpu limit', status: 503, cause: 'cpu' }, 'cpu'],
    [{ trap: 'out of memory', status: 503, cause: 'oom' }, 'oom'],
    [{ trap: 'out of memory: request block', status: 503, cause: 'oom' }, 'oom'],
    [{ trap: 'shed: all task slots are in use', status: 503, shed: true }, 'shed'],
    [{ trap: 'shed: a grow was denied in the last graceMs', status: 503, shed: true, reason: 'x' }, 'shed'],
    [{ trap: 'cancelled: deadline', status: 503, cancelled: 'deadline' }, 'deadline'],
    [{ trap: 'cancelled: replace', status: 503, cancelled: 'replace' }, 'cancelled'],
    [{ trap: 'cancelled: signal', status: 503, cancelled: 'signal' }, 'cancelled'],
    [{ trap: 'the event cannot cross: x', status: 500, cause: 'event' }, 'event'],
    [{ outcome: { outcome: 'failed', message: 'Boom' } }, 'failed'],
    [{ outcome: { outcome: 'unhandled' } }, 'failed'],
  ];
  const bad = rows.filter(([r, want]) => causeOf(r) !== want).map(([r, want]) => `${JSON.stringify(r)}: ${causeOf(r)}, want ${want}`);
  check('2a causeOf: each runner result has its cause (TR2)', bad.length === 0, bad.join('; '));
  check('2b each cause of TR2 is a field of the table', rows.every(([, want]) => TRAP_CAUSES.includes(want)), '');
}

// ---- 3 (TR1, TR7): trapResponse with no table ----
{
  const crash = trapResponse(null, { trap: 'RuntimeError: unreachable' }, '1');
  const text = await crash.text();
  check('3a crash: the 0.0.2 response (500, trap text, text/plain, no retry-after)', crash.status === 500 && text === 'trap RuntimeError: unreachable' && crash.headers.get('content-type') === 'text/plain;charset=UTF-8' && !crash.headers.has('retry-after'), `${crash.status} ${text} ${[...crash.headers]}`);
  const oom = trapResponse(null, { trap: 'out of memory', status: 503, cause: 'oom' }, '2');
  check('3b oom: 503, the trap text, and retry-after (O2)', oom.status === 503 && (await oom.text()) === 'trap out of memory' && oom.headers.get('retry-after') === '2' && oom.headers.get('content-type') === 'text/plain;charset=UTF-8', [...oom.headers].join());
  const shed = trapResponse(null, { trap: 'shed: all task slots are in use', status: 503, shed: true }, '1');
  check('3c shed: 503 with retry-after (O2)', shed.status === 503 && shed.headers.get('retry-after') === '1', [...shed.headers].join());
  const dl = trapResponse(null, { trap: 'cancelled: deadline', status: 503, cancelled: 'deadline' }, '1');
  check('3d deadline: no retry-after', dl.status === 503 && !dl.headers.has('retry-after'), [...dl.headers].join());
  const f = trapResponse(null, { outcome: { outcome: 'failed', message: 'x' } }, '1');
  check('3e failed: 500 with no body', f.status === 500 && f.body === null, `${f.status} ${f.body}`);
}

// ---- 4 (T3, T4, T6, T7): app_trap.wasm ----
const Box = objectClass('Box');
const Ep = entrypointClass('Ep');
const lines = [];
const ops = { never: () => new Promise(() => {}) };
const appTrap = wasm('app_trap.wasm');
const handlerOf = (opts = {}) => makeHandler(appTrap, { ops, log: (t) => lines.push(t), heapCheckWhenIdle: false, ...opts });
const title = (r) => {
  try {
    return JSON.parse(r.body).title;
  } catch {
    return `not JSON: ${r.body}`;
  }
};
const problem = (r, status, t) => r.status === status && r.headers['content-type'] === 'application/problem+json' && r.headers['cache-control'] === 'no-store' && title(r) === t && JSON.parse(r.body).status === status;
{
  const H = handlerOf();
  const get = async (path, init) => read(await new H(ctx, env).fetch(new Request(`http://x${path}`, init)));
  const table = checkManifest(manifestOf(appTrap, manifestEvent())).traps;
  check('4a the manifest has the table of on_trap: default first, the given causes in order', Object.keys(table).join() === 'default,crash,oom,shed,deadline,cancelled,failed' && new TextDecoder().decode(table.crash.body).includes('Crashed'), Object.keys(table).join());
  const ok = await get('/ok');
  check('4b a good request is not changed', ok.status === 200 && ok.body === 'ok', JSON.stringify(ok));
  // T3: two crash requests: each gets the full body (a new body for each response, TR4).
  const c1 = await get('/crash');
  const c2 = await get('/crash');
  check('4c crash: the entry crashed (500, problem+json, no-store, title Crashed)', problem(c1, 500, 'Crashed') && !('retry-after' in c1.headers), JSON.stringify(c1));
  check('4d a second crash gets the full body again (TR4)', problem(c2, 500, 'Crashed') && c2.body === c1.body, JSON.stringify(c2));
  check('4e the crash text is in the log, not in the response (TR8)', lines.some((l) => l.includes('the crash text of app_trap')) && !c1.body.includes('crash text'), lines.join(' | '));
  const e = await get('/err');
  check('4f Err: the entry failed (502)', problem(e, 502, 'Failed'), JSON.stringify(e));
  // T4 event: a value that cannot cross (J1: a header value that is a BigInt outside i64). No field event: default.
  const fake = { method: 'GET', url: 'http://x/ok', headers: [['x-big', 2n ** 70n]], body: null, signal: new AbortController().signal, cf: undefined };
  const ev = await read(await new H(ctx, env).fetch(fake));
  check('4g event (no field): the entry default (500, Internal error)', problem(ev, 500, 'Internal error'), JSON.stringify(ev));
  // T7: the fetch of an object class and of a named entry point use the table (revert check S3: skip it in fetchLike).
  const octx = { id: { toString: () => 'box-1' }, storage: { sql: { databaseSize: 0 } }, waitUntil() {}, blockConcurrencyWhile: (f) => f() };
  const ob = await read(await new Box(octx, env).fetch(new Request('http://x/crash')));
  check('4h object class fetch: the entry crashed', problem(ob, 500, 'Crashed'), JSON.stringify(ob));
  const ep = await read(await new Ep(ctx, env).fetch(new Request('http://x/err')));
  check('4i entry point fetch: the entry failed', problem(ep, 502, 'Failed'), JSON.stringify(ep));
  const epc = await read(await new Ep(ctx, env).fetch(new Request('http://x/crash')));
  check('4j entry point fetch, crash: the entry crashed', problem(epc, 500, 'Crashed'), JSON.stringify(epc));
  // T7: a trap after Response.after does not change the sent response.
  const waits = [];
  const actx = { waitUntil: (p) => waits.push(p) };
  const n0 = lines.length;
  const af = await read(await new H(actx, env).fetch(new Request('http://x/after')));
  await Promise.all(waits);
  check('4k Response.after then a crash: the sent response stays (200 early)', af.status === 200 && af.body === 'early' && lines.slice(n0).some((l) => l.includes('a crash in the work after the response')), `${JSON.stringify(af)} ${lines.slice(n0).join(' | ')}`);
  // T7: pass_through! then a crash: still a throw.
  let threw = null;
  try {
    await new H({ waitUntil() {}, passThroughOnException() {} }, env).fetch(new Request('http://x/pass'));
  } catch (x) {
    threw = x.message;
  }
  check('4l pass_through! then a crash: a throw, not the table', /fetch: trap/.test(threw ?? ''), String(threw));
  // T4 cancelled: the client goes away (request.signal).
  const ac = new AbortController();
  const pending = new H(ctx, env).fetch(new Request('http://x/wait', { signal: ac.signal }));
  await sleep(20);
  ac.abort();
  const cn = await read(await pending);
  check('4m cancelled (signal): the entry cancelled (503), no retry-after', problem(cn, 503, 'Cancelled') && !('retry-after' in cn.headers), JSON.stringify(cn));
}
// T4 deadline: a task past taskDeadlineMs.
{
  const H = handlerOf({ taskDeadlineMs: 100 });
  const dl = await read(await new H(ctx, env).fetch(new Request('http://x/wait')));
  check('4n deadline: the entry deadline (504)', problem(dl, 504, 'Deadline'), JSON.stringify(dl));
}
// T4, T6: OOM (a list of 20 MiB in an isolate of 16 MiB), then a shed by memory pressure (graceMs 3000).
{
  const H = handlerOf({ isolateBytes: 16 * MB, jsReserveBytes: 0, graceMs: 3000 });
  const get = async (path) => read(await new H(ctx, env).fetch(new Request(`http://x${path}`)));
  const before = H.runner.stats.oom;
  const oom = await get('/big/20');
  check('4o oom: the entry oom (503), with the retry-after of the app (7), not the one of the shim (T6)', problem(oom, 503, 'Out of memory') && oom.headers['retry-after'] === '7' && H.runner.stats.oom === before + 1, JSON.stringify(oom));
  const shed = await get('/ok');
  check('4p shed (pressure): the entry shed (503), retry-after ceil(graceMs / 1000) = 3 added by the shim (TR7)', problem(shed, 503, 'Shed') && shed.headers['retry-after'] === '3', JSON.stringify(shed));
  await sleep(3100);
  const ok = await get('/ok');
  check('4q after graceMs the instance answers again', ok.status === 200 && ok.body === 'ok', JSON.stringify(ok));
}

// ---- 5 (T5): no export, no wasm memory, no handle between the trap and the response ----
{
  const tlines = [];
  // `run` writes the log line `fetch: trap: ...` (or `fetch: failed: ...`) after the runner result and before the response.
  const H = makeHandler(appTrap, { ops, heapCheckWhenIdle: false, log: (t) => (tlines.push(t), /^(\w+(\.\w+)?): (trap|failed)/.test(t) && (armed = true)) });
  const tryOne = async (name, make) => {
    reads.length = 0;
    const res = await make();
    armed = false;
    await res.text();
    check(`5 ${name}: 0 reads of an export between the trap and the response`, reads.length === 0, `read: ${reads.join(', ')}`);
  };
  await tryOne('crash', () => new H(ctx, env).fetch(new Request('http://x/crash')));
  await tryOne('Err', () => new H(ctx, env).fetch(new Request('http://x/err')));
  await tryOne('entry point crash', () => new Ep(ctx, env).fetch(new Request('http://x/crash')));
  check('5 control: the counter sees reads while armed', (() => {
    armed = true;
    void H.runner.x.live_bytes;
    armed = false;
    return reads.includes('live_bytes');
  })(), 'the proxy did not count');
}

// ---- 6 (T8, TR1, O2): app_trap_none.wasm (bench/app_trap.roc with no on_trap, made by bench/build.sh) ----
{
  const H = makeHandler(wasm('app_trap_none.wasm'), { ops, log: () => {}, heapCheckWhenIdle: false, isolateBytes: 16 * MB, jsReserveBytes: 0 });
  const c = await read(await new H(ctx, env).fetch(new Request('http://x/crash')));
  check('6a no on_trap, crash: 500, trap RuntimeError: unreachable, text/plain, no retry-after', c.status === 500 && c.body === 'trap RuntimeError: unreachable' && c.headers['content-type'] === 'text/plain;charset=UTF-8' && !('retry-after' in c.headers), JSON.stringify(c));
  const e = await new H(ctx, env).fetch(new Request('http://x/err'));
  const o = await read(await new Box({ id: { toString: () => 'box-2' }, storage: { sql: { databaseSize: 0 } }, waitUntil() {} }, env).fetch(new Request('http://x/crash')));
  check('6e no on_trap, object class fetch: the 0.0.2 crash response', o.status === 500 && o.body === 'trap RuntimeError: unreachable' && !('retry-after' in o.headers), JSON.stringify(o));
  check('6b no on_trap, Err: 500 with no body', e.status === 500 && e.body === null, `${e.status}`);
  const big = await read(await new H(ctx, env).fetch(new Request('http://x/big/20')));
  check('6c no on_trap, oom: 503, the trap text, retry-after 1 (O2)', big.status === 503 && big.body.startsWith('trap out of memory') && big.headers['retry-after'] === '1', JSON.stringify(big));
  const shed = await read(await new H(ctx, env).fetch(new Request('http://x/ok')));
  check('6d no on_trap, shed: 503, the trap text, retry-after 1 (O2)', shed.status === 503 && shed.body.startsWith('trap shed:') && shed.headers['retry-after'] === '1', JSON.stringify(shed));
}
console.log(failed ? 'FAILED' : 'all passed');
process.exit(failed ? 1 : 0);
