// Typed RPC errors and per-handler error types (PLAN.md 8h items 1 and 2): routes of conformance/RpcErrRoutes.roc. The
// callee `busy` gives `Ok(2)`, `Err(Busy("later"))` or `Err(StillOpen)`; the caller matches the exact tag. Three callees:
// the default export (`self`), the named entry point `Admin` (`admin`), a Durable Object of `Counter` (`obj`).
import { answer, eq, ok } from '../assert.mjs';
import { canon } from '../canon.mjs';

export const options = {};

// N5 G1a: the texts of the errors of the platform calls of a callee (the same as the checks of objects.mjs and d1.mjs).
const SQL = ['Error', 'near "SELEC": syntax error at offset 0: SQLITE_ERROR'];
const STORAGE = ['TypeError', 'Your Durable Object class must have an alarm() handler in order to call setAlarm()'];
const CONSTRAINT = ['PrimaryKey', 'UNIQUE constraint failed: uniq.k'];
// The reply of a callee that `?`s a platform error, as a JS caller reads it: `{ Err: { Infra: { <tag>: payload } } }`.
const infra = (tag, payload) => ({ Err: { Infra: { [tag]: payload } } });
const thrown = ([name, message]) => ({ name, message });

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
  // examples/auction/REVIEW.md N1: the answer type `{}` (Rpc.reply_of reads the head by hand, research/rpc-unit-crash).
  ['rpcerr an answer {}: Ok({}) and Err(Remote(AlreadyOpen)) on an entry point, a named entry point and an object', async (t) => {
    for (const [k, base] of targets) {
      answer(await route(t, base, 'unit', 'n=1'), 'Ok {}');
      answer(await route(t, base, 'unit', 'n=2'), 'AlreadyOpen');
    }
  }],
  ['rpcerr an answer {} with ? (the shape of examples/auction)', async (t) => {
    answer(await t.get('/rpcerr/obj/unit_try?name=e&n=1'), 'opened');
    answer(await t.get('/rpcerr/obj/unit_try?name=e&n=2'), 'AlreadyOpen');
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
  // N5 G1a: a callee `?`s a platform error. `err` is `[NotOpen, Infra(Rpc.Infra)]`: the caller gets `Remote(Infra(<tag>))` with the
  // tag and the payload intact (matched by the tag in `fail_text` of RpcErrRoutes.roc), and `Remote(NotOpen)` for a domain error.
  ['rpcerr infra: a Durable Object callee that ?s a SQL error: the caller gets Remote(Infra(SqlErr)) with name and message', async (t) =>
    answer(await t.get('/rpcerr/store/fail?name=i1&kind=sql'), `Remote SqlErr ${SQL.join(' | ')}`)],
  ['rpcerr infra: a Durable Object callee that ?s a storage error: Remote(Infra(StorageErr)) with name and message', async (t) =>
    answer(await t.get('/rpcerr/store/fail?name=i2&kind=storage'), `Remote StorageErr ${STORAGE.join(' | ')}`)],
  ['rpcerr infra: a Durable Object callee that ?s a constraint error: Remote(Infra(Constraint)) with the kind and the message', async (t) =>
    answer(await t.get('/rpcerr/store/fail?name=i3&kind=constraint'), `Remote Constraint ${CONSTRAINT[0]} | ${CONSTRAINT[1]}`)],
  ['rpcerr infra: a Workers callee (default entry point and Admin) that ?s a D1 error: Remote(Infra(D1Err))', async (t) => {
    for (const k of ['self', 'admin']) {
      const r = await t.get(`/rpcerr/${k}/fail?kind=d1`);
      ok(r.status === 200 && /^Remote D1Err \w+ \| .*SQLITE_ERROR/.test(r.body), `${k}: got ${r.status} ${r.body.slice(0, 300)}`);
    }
  }],
  ['rpcerr infra: a domain error of the same callee is still Remote(NotOpen), and Ok is Ok', async (t) => {
    answer(await t.get('/rpcerr/store/fail?name=i4&kind=domain'), 'NotOpen');
    answer(await t.get('/rpcerr/store/fail?name=i4&kind=ok'), 'Ok 7');
    for (const k of ['self', 'admin']) {
      answer(await t.get(`/rpcerr/${k}/fail?kind=domain`), 'NotOpen');
      answer(await t.get(`/rpcerr/${k}/fail?kind=ok`), 'Ok 7');
    }
  }],
  ['rpcerr infra: a callee that crashes is Infra(RpcErr) of the caller, not Remote', async (t) => {
    for (const [base, extra] of [['store', '&name=i5'], ['self', ''], ['admin', '']]) {
      const r = await t.get(`/rpcerr/${base}/fail?kind=crash${extra}`);
      ok(r.status === 200 && r.body.startsWith('RpcErr '), `${base}: got ${r.status} ${r.body.slice(0, 200)}`);
    }
  }],
  ['rpcerr infra: a JS callee that gives { Err: { Infra: { StorageErr } } } is Remote(Infra(StorageErr)), a domain tag Remote(NotOpen)', async (t) => {
    answer(await t.get('/rpcerr/self/jsfail?kind=storage'), 'Remote StorageErr Error | js storage');
    answer(await t.get('/rpcerr/self/jsfail?kind=domain'), 'NotOpen');
    answer(await t.get('/rpcerr/self/jsfail?kind=ok'), 'Ok 7');
  }],
  ['rpcerr infra: a reply with an infra tag that Rpc.Infra has not is Infra(BadData)', async (t) =>
    answer(await t.get('/rpcerr/self/jsfail?kind=badtag'), 'BadData')],
  // Rpc.forward (MODULES.md 8): the callee calls `fail` and passes the errors on. `|e| e` keeps the domain tag, a mapping changes it,
  // and an `Infra` error of the inner callee is `Remote(Infra(..))` of the outer caller, with its tag and payload.
  ['rpcerr forward |e| e: an inner domain error is the same Remote(NotOpen), an inner infra error is Remote(Infra(..)) of the outer caller', async (t) => {
    answer(await t.get('/rpcerr/obj/relay?name=f1&kind=domain'), 'NotOpen');
    answer(await t.get('/rpcerr/obj/relay?name=f1&kind=ok'), 'Ok 7');
    answer(await t.get('/rpcerr/obj/relay?name=f1&kind=sql'), `Remote SqlErr ${SQL.join(' | ')}`);
    answer(await t.get('/rpcerr/obj/relay?name=f1&kind=storage'), `Remote StorageErr ${STORAGE.join(' | ')}`);
    answer(await t.get('/rpcerr/obj/relay?name=f1&kind=constraint'), `Remote Constraint ${CONSTRAINT[0]} | ${CONSTRAINT[1]}`);
    for (const k of ['self', 'admin']) {
      answer(await t.get(`/rpcerr/${k}/relay?kind=domain`), 'NotOpen');
      const r = await t.get(`/rpcerr/${k}/relay?kind=d1`);
      ok(r.status === 200 && /^Remote D1Err \w+ \| .*SQLITE_ERROR/.test(r.body), `${k}: got ${r.status} ${r.body.slice(0, 300)}`);
    }
  }],
  ['rpcerr forward with a domain mapping: NotOpen of the inner callee is Remote(Shut), an inner infra error is kept', async (t) => {
    answer(await t.get('/rpcerr/obj/relay_map?name=f2&kind=domain'), 'Shut');
    answer(await t.get('/rpcerr/obj/relay_map?name=f2&kind=ok'), 'Ok 7');
    answer(await t.get('/rpcerr/obj/relay_map?name=f2&kind=sql'), `Remote SqlErr ${SQL.join(' | ')}`);
    for (const k of ['self', 'admin']) {
      answer(await t.get(`/rpcerr/${k}/relay_map?kind=domain`), 'Shut');
      const r = await t.get(`/rpcerr/${k}/relay_map?kind=d1`);
      ok(r.status === 200 && /^Remote D1Err \w+ \| .*SQLITE_ERROR/.test(r.body), `${k}: got ${r.status} ${r.body.slice(0, 300)}`);
    }
  }],
  ['rpcerr forward: a failure of the inner call itself (the inner callee crashes) is Remote(Infra(RpcErr)) of the outer caller', async (t) => {
    for (const [route, extra] of [['obj/relay', '&name=f3'], ['self/relay', ''], ['admin/relay', '']]) {
      const r = await t.get(`/rpcerr/${route}?kind=crash${extra}`);
      ok(r.status === 200 && r.body.startsWith('Remote RpcErr '), `${route}: got ${r.status} ${r.body.slice(0, 200)}`);
    }
    const m = await t.get('/rpcerr/obj/relay_map?name=f3&kind=crash');
    ok(m.status === 200 && m.body.startsWith('Remote RpcErr '), `relay_map: got ${m.status} ${m.body.slice(0, 200)}`);
  }],
  // The wire: a JS caller reads the reply of `fail`, `relay` and `relay_map` as `{ Err: { Infra: { <tag>: payload } } }`. A tag with
  // no payload is text (`{ Err: "NotOpen" }`), a tag with a record has the fields of the record.
  ['rpcerr infra: the reply on the wire for a JS caller is { Err: { Infra: { <tag>: payload } } }, also when forwarded', async (t) => {
    const r = await t.get('/__wire_infra');
    eq(r.status, 200, 'status');
    const sql = infra('SqlErr', thrown(SQL)), storage = infra('StorageErr', thrown(STORAGE));
    const d1 = JSON.parse(r.body).self.d1;
    ok(typeof d1?.Err?.Infra?.D1Err?.name === 'string' && /SQLITE_ERROR/.test(d1.Err.Infra.D1Err.message ?? ''), `d1: ${JSON.stringify(d1)}`);
    const want = {
      store: { sql, constraint: infra('Constraint', { kind: CONSTRAINT[0], message: CONSTRAINT[1] }), storage, domain: { Err: 'NotOpen' } },
      self: { d1, domain: { Err: 'NotOpen' } },
      admin: { d1 },
      relay: { sql, storage, domain: { Err: 'NotOpen' } },
      relay_map: { sql, domain: { Err: 'Shut' } },
    };
    eq(canon(JSON.parse(r.body)), canon(want), 'the replies');
  }],
];
