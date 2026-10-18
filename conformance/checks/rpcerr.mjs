// Typed RPC errors and per-handler error types (PLAN.md 8h items 1 and 2): routes of conformance/RpcErrRoutes.roc. The
// callee `busy` gives `Ok(2)`, `Err(Busy("later"))` or `Err(StillOpen)`; the caller matches the exact tag. Three callees:
// the default export (`self`), the named entry point `Admin` (`admin`), a Durable Object of `Counter` (`obj`).
import { answer, eq, ok } from '../assert.mjs';

export const options = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const targets = [['self', '/rpcerr/self'], ['admin', '/rpcerr/admin'], ['obj', '/rpcerr/obj']];
const route = (t, base, c, extra = '') => t.get(`${base}/${c}?name=e&${extra}`);
// Waits for a log line of workerd that has `text`.
async function logged(t, text) {
  for (let i = 0; i < 100; i++) {
    const l = t.logs.find((l) => String(l.message).includes(text));
    if (l) return l;
    await sleep(25);
  }
  throw new Error(`no log line with ${JSON.stringify(text)}`);
}

export const checks = [
  ['rpcerr Ok value: a default entry point, a named entry point and an object', async (t) => {
    for (const [k, base] of targets) answer(await route(t, base, 'busy', 'n=1'), 'Ok 2');
  }],
  ['rpcerr Err with a payload tag: the caller matches Busy(Str)', async (t) => {
    for (const [k, base] of targets) answer(await route(t, base, 'busy', 'n=2'), 'Busy later');
  }],
  ['rpcerr Err with a tag with no payload: the caller matches StillOpen', async (t) => {
    for (const [k, base] of targets) answer(await route(t, base, 'busy', 'n=3'), 'StillOpen');
  }],
  ['rpcerr a Roc callee that crashes: RpcErr', async (t) => {
    for (const [k, base] of targets) {
      const r = await route(t, base, 'crash', 'n=1');
      ok(r.status === 200 && r.body.startsWith('RpcErr '), `${k}: got ${r.status} ${r.body.slice(0, 200)}`);
    }
  }],
  ['rpcerr a JS callee that throws: RpcErr with the message', async (t) =>
    answer(await t.get('/rpcerr/self/jsthrow?n=1'), 'RpcErr js callee throw')],
  ['rpcerr a JS callee: the plain objects { Ok } and { Err } are Ok, Busy and StillOpen', async (t) => {
    answer(await t.get('/rpcerr/self/jsbusy?n=1'), 'Ok 2');
    answer(await t.get('/rpcerr/self/jsbusy?n=2'), 'Busy js');
    answer(await t.get('/rpcerr/self/jsbusy?n=3'), 'StillOpen');
  }],
  ['rpcerr a reply { Err } for a method with Rpc.NoErr is BadData', async (t) => {
    for (const [k, base] of targets) answer(await route(t, base, 'stray', 'n=1'), 'BadData');
  }],
  ['rpcerr an argument that does not parse is RpcErr with "bad argument"', async (t) => {
    for (const [k, base] of targets) {
      const r = await route(t, base, 'badarg', 'n=1');
      ok(r.status === 200 && r.body.startsWith('RpcErr bad argument: '), `${k}: got ${r.status} ${r.body.slice(0, 200)}`);
    }
  }],
  // The bytes of a reply: a JS caller gets the plain object `{"Ok": v}` or `{"Err": tag}` (the derived CBOR of a tag).
  ['rpcerr the reply on the wire is {"Ok": v} and {"Err": tag} for a JS caller', async (t) => {
    const r = await t.get('/__wire');
    const one = JSON.stringify([{ Ok: 2 }, { Err: { Busy: 'later' } }, { Err: 'StillOpen' }]);
    answer(r, `{"self":${one},"admin":${one},"obj":${one}}`);
  }],
  // 8h item 1: each handler has its own error type, and an `Err` is a log line with `Str.inspect` of it.
  ['rpcerr Worker.new: an Err of fetch! is a log line and a 500 (FetchFail)', async (t) => {
    const r = await t.get('/fail');
    eq(r.status, 500, 'status');
    await logged(t, 'fetch: failed: FetchFail("fetch")');
  }],
  ['rpcerr Worker.new: an Err of scheduled! is a log line (UnknownCron)', async (t) => {
    const r = await t.mf.dispatchFetch('http://localhost/cdn-cgi/local/scheduled?cron=bad');
    ok(r.status !== 200, `status ${r.status}`);
    await logged(t, 'scheduled: failed: UnknownCron("bad")');
    const good = await t.mf.dispatchFetch('http://localhost/cdn-cgi/local/scheduled?cron=good');
    eq(good.status, 200, 'a cron that is known');
  }],
  ['rpcerr Worker.new: an Err of queue! is a log line (Boom)', async (t) => {
    const w = await t.mf.getWorker();
    const r = await w.queue('handler-err', [{ id: 'e1', timestamp: new Date(1_700_000_000_000), body: 1, attempts: 1 }]);
    eq(r.outcome, 'exception', 'outcome');
    await logged(t, 'queue: failed: Boom');
  }],
  ['rpcerr Worker.new: an Err of email! is a log line (Boom)', async (t) => {
    const to = 'err@example.com';
    const body = `From: sender@example.com\r\nTo: ${to}\r\nSubject: s\r\nMessage-ID: <e1@example.com>\r\nDate: Thu, 15 Oct 2026 10:00:00 +0000\r\nContent-Type: text/plain\r\n\r\nx\r\n`;
    await t.mf.dispatchFetch(`http://localhost/cdn-cgi/local/email?from=sender%40example.com&to=${encodeURIComponent(to)}&format=json`, { method: 'POST', body });
    await logged(t, 'email: failed: Boom');
  }],
];
