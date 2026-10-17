// PLAN.md 8b (first half), in Node: the entry `event!` (API.md 10.1), `makeHandler` as a `WorkerEntrypoint` subclass,
// the `Worker` wrapper (MODULES.md 3), `Request`, `Response` and `Body` with buffered bodies (MODULES.md 4), the cron
// rules (MODULES.md 3) and the crash text in the log (8a O2). The app is bench/app_events.roc.
// node bench/entry-test.mjs bench/out/app_events.wasm
// `cloudflare:workers` is the stand-in of bench/cf-workers-stub.mjs (bench/cf-node.mjs). workerd: bench/entry-workerd.mjs.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { makeHandler, WorkerEntrypoint } from './cf-node.mjs';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const lines = [];
const Handler = makeHandler(module, { other: ['ping'], log: (text) => lines.push(text) });
const env = { name: 'env' };
const ctx = { waitUntil() {} };
const h = () => new Handler(ctx, env);
// The log lines that one call writes.
const logOf = async (f) => {
  const n = lines.length;
  const r = await f();
  return { r, log: lines.slice(n).join(' | ') };
};

// 1. The class of the default export is a subclass of `WorkerEntrypoint`, and its methods are on its prototype.
{
  const sub = Handler.prototype instanceof WorkerEntrypoint;
  const own = ['fetch', 'scheduled', 'queue', 'ping'].every((m) => Object.hasOwn(Handler.prototype, m));
  const inst = h();
  console.log('1 subclass:', { sub, own, env: inst.env === env, ctx: inst.ctx === ctx });
  if (!sub) fail('1: makeHandler does not give a subclass of WorkerEntrypoint');
  if (!own || inst.env !== env || inst.ctx !== ctx) fail('1: the methods are not on the prototype, or env and ctx are not kept');
}

// 1b. QO5 (PLAN.md 8f, part 2): `queue`, `email` and `tail` only for an app whose manifest has the handler. app_events
// has `queue!` and no `email!` or `tail!`. app_stream (in the same directory) has no `queue!`.
{
  const names = (C) => ['queue', 'email', 'tail'].filter((m) => m in C.prototype);
  const events = names(Handler);
  const stream = names(makeHandler(new WebAssembly.Module(readFileSync(new URL('app_stream.wasm', pathToFileURL(process.argv[2])))), { log: () => {} }));
  // PLAN.md 8f, part 3: app.wasm has a raw `event!` (no `Worker` wrapper): it answers `Unhandled` to `Manifest`, and keeps
  // all three methods, so its `event!` gets these events.
  const raw = names(makeHandler(new WebAssembly.Module(readFileSync(new URL('app.wasm', pathToFileURL(process.argv[2])))), { log: () => {} }));
  console.log('1b QO5:', { app_events: events, app_stream: stream, app: raw });
  if (events.join() !== 'queue') fail(`1b: app_events (queue! only) has ${JSON.stringify(events)}, want ["queue"]`);
  if (stream.length !== 0) fail(`1b: app_stream (no queue!, email!, tail!) has ${JSON.stringify(stream)}, want []`);
  if (raw.join() !== 'queue,email,tail') fail(`1b: app (a raw event!, the manifest is Unhandled) has ${JSON.stringify(raw)}, want ["queue","email","tail"]`);
}

// 2. A binary body (0x00 to 0xFF) comes back with the same bytes. With the body as a `Str`, the bytes above 0x7F change.
{
  const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
  const res = await h().fetch(new Request('http://x/echo', { method: 'POST', body: bytes }));
  const got = new Uint8Array(await res.arrayBuffer());
  const same = got.length === 256 && got.every((b, i) => b === i);
  console.log('2 binary body:', { status: res.status, type: res.headers.get('content-type'), length: got.length, same });
  if (res.status !== 200 || !same) fail(`2: the body did not come back: status ${res.status}, ${got.length} bytes`);
  if (res.headers.get('content-type') !== 'application/octet-stream') fail('2: content-type');
}

// 3. 100 request headers come back as 100 response headers. 4. Status 404.
{
  const headers = new Headers();
  for (let i = 0; i < 100; i++) headers.set(`x-h-${i}`, `v${i}-${'z'.repeat(i)}`);
  const res = await h().fetch(new Request('http://x/headers', { headers }));
  const back = [...res.headers].filter(([k]) => k.startsWith('x-h-'));
  const same = back.length === 100 && back.every(([k, v]) => headers.get(k) === v);
  console.log('3 headers:', { status: res.status, back: back.length, same });
  if (res.status !== 200 || !same) fail(`3: ${back.length} headers came back`);
  const missing = await h().fetch(new Request('http://x/missing'));
  console.log('4 status:', missing.status);
  if (missing.status !== 404) fail(`4: status ${missing.status}, want 404`);
}

// 4b. A JSON body in and out (`Request.json!`, `Response.from_json`).
{
  const res = await h().fetch(new Request('http://x/json', { method: 'POST', body: '{"n":41}' }));
  const text = await res.text();
  console.log('4b json:', res.status, res.headers.get('content-type'), text);
  if (res.status !== 200 || text !== '{"n":42}' || res.headers.get('content-type') !== 'application/json') fail(`4b: ${res.status} ${text}`);
}

// 5. Cron runs, with a fake controller. Only `no_retry!` calls `noRetry` (MODULES.md 3).
const controller = (cron, scheduledTime) => ({
  cron,
  scheduledTime,
  noRetried: false,
  noRetry() {
    this.noRetried = true;
  },
});
const cron = async (c) => {
  const { r, log } = await logOf(() => h().scheduled(c).then(() => 'ok', (e) => `throw ${e.message}`));
  return { outcome: r, noRetry: c.noRetried, log };
};
{
  const cases = [
    ['5a the cron and time_ms reach scheduled!', controller('*/5 * * * *', 1_700_000_000_000), 'ok', false, null],
    ['5b Err: a failed run, no noRetry', controller('fail', 1_700_000_000_000), 'throw', false, /Failing/],
    ['5c no_retry! then Err: noRetry', controller('noretry', 1_700_000_000_000), 'throw', true, /Failing/],
    ['5d no scheduled!: a failed run, no noRetry', controller('none', 1_700_000_000_000), 'throw', false, /unhandled/],
  ];
  for (const [name, c, outcome, noRetry, log] of cases) {
    const r = await cron(c);
    console.log(name, r);
    if (!r.outcome.startsWith(outcome) || r.noRetry !== noRetry) fail(`${name}: got ${r.outcome}, noRetry ${r.noRetry}`);
    if (log && !log.test(r.log)) fail(`${name}: no log line with ${log}: ${r.log}`);
  }
}

// 6. `ping` in the option `other` reaches `Other` (`queue`, `email` and `tail` have their own entry points since 8f). The `Ok(v)` of `other!` is the value that the caller gets.
{
  const payload = { messages: [1, 2], queue: 'jobs' };
  let got;
  try {
    got = await h().ping(payload);
  } catch (e) {
    got = `throw ${e}`;
  }
  const ok = got?.kind === 'ping' && JSON.stringify(got.got) === JSON.stringify(payload);
  console.log('6 other:', got, { pong: typeof Handler.prototype.pong });
  if (!ok) fail(`6: ping gave ${JSON.stringify(got)}`);
  if (typeof Handler.prototype.pong !== 'undefined') fail('6: a name that is not in `other` has a method');
}

// 7. `Unhandled`: a 500 and a log line. 8. `Err`: `Failed`, a 500 with no body and a log line with the error.
// 9. A `crash`: a 500 and its text in the log line.
{
  const u = await logOf(() => h().fetch(new Request('http://x/unhandled')));
  console.log('7 unhandled:', u.r.status, u.log);
  if (u.r.status !== 500 || !/^fetch: unhandled/.test(u.log)) fail(`7: ${u.r.status} ${u.log}`);
  const e = await logOf(() => h().fetch(new Request('http://x/err')));
  const body = await e.r.text();
  console.log('8 err:', e.r.status, JSON.stringify(body), e.log);
  if (e.r.status !== 500 || body !== '' || !/^fetch: failed: Boom\(42\)$/.test(e.log)) fail(`8: ${e.r.status} ${body} ${e.log}`);
  const c = await logOf(() => h().fetch(new Request('http://x/crash')));
  console.log('9 crash:', c.r.status, c.log);
  if (c.r.status !== 500 || !/the crash text of app_events/.test(c.log)) fail(`9: no crash text in the log line: ${c.log}`);
}

// 10. `request.cf` in the tag form: a field that is set is `Ok`, a field that is not set is `Missing`, never null.
{
  const req = new Request('http://x/cf');
  Object.defineProperty(req, 'cf', { value: { colo: 'WAW', asn: 13335, clientTcpRtt: 12, isEUCountry: '1', city: null } });
  const text = await (await h().fetch(req)).text();
  const none = await (await h().fetch(new Request('http://x/cf'))).text();
  console.log('10 cf:', text, '|', none);
  if (text !== 'colo=Ok(WAW) city=Missing asn=Ok(13335) rtt=Ok(12) eu' || none !== 'no cf') fail(`10: ${text} | ${none}`);
}

const live = Handler.runner.x.live_bytes();
console.log({ live, tasks: Handler.runner.tasks.size, alarms: Handler.runner.stats.alarms });
if (live !== 0 || Handler.runner.tasks.size !== 0 || Handler.runner.stats.alarms !== 0) fail('live bytes, tasks or alarms not 0');
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
