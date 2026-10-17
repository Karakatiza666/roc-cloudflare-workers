// `Http` (MODULES.md 4) and its error map (MC9, PLAN.md 8d): routes of conformance/HttpRoutes.roc. `t.server` is the
// local server of run.mjs. Each check gives the text that the route answered.
import { answer, ok } from '../assert.mjs';

export const options = {};

const q = (url) => encodeURIComponent(url);
// One wait for each crossing: `send!` reads the body in its crossing.
const once = (r, n = 1) => ok(r.waits === n, `${r.waits} waits, want ${n}`);

export const checks = [
  ['http send!', async (t) => {
    const r = await t.get(`/http/send?url=${q(t.server + '/hello')}`);
    answer(r, '200 hello');
    once(r);
  }],
  ['http send (Io twin)', async (t) => {
    const r = await t.get(`/http/send_io?url=${q(t.server + '/hello')}`);
    answer(r, '200 hello');
    once(r);
  }],
  ['http send! of a status 404 is Ok', async (t) => answer(await t.get(`/http/send?url=${q(t.server + '/status/404')}`), '404 ')],
  // A 204 response has a null body: `pf.readUpTo` reads it as no bytes.
  ['http send! of a 204 (no body)', async (t) => answer(await t.get(`/http/send?url=${q(t.server + '/status/204')}`), '204 ')],
  ['http send! with a body and a header', async (t) => answer(await t.get(`/http/post?url=${q(t.server + '/echo')}`), '200 POST yes a body')],
  ['http send_with! max_bytes', async (t) => {
    answer(await t.get(`/http/send_with?max=4&url=${q(t.server + '/ten')}`), 'TooLarge');
    answer(await t.get(`/http/send_with?max=10&url=${q(t.server + '/ten')}`), '200 0123456789');
  }],
  ['http send_with (Io twin)', async (t) => {
    answer(await t.get(`/http/send_with_io?max=4&url=${q(t.server + '/ten')}`), 'TooLarge');
    answer(await t.get(`/http/send_with_io?max=10&url=${q(t.server + '/ten')}`), '200 0123456789');
  }],
  ['http send_with! timeout_ms', async (t) => {
    const r = await t.get(`/http/timeout?ms=100&url=${q(t.server + '/slow')}`);
    ok(r.body.startsWith('Network ') && r.ms < 1500, `got ${r.body} after ${r.ms} ms, want Network before the 2 s answer`);
    return r.body;
  }],
  ['http open!', async (t) => {
    const r = await t.get(`/http/open?url=${q(t.server + '/hello')}`);
    answer(r, '200 stream hello');
    once(r, 2);
  }],
  ['http open (Io twin)', async (t) => answer(await t.get(`/http/open_io?url=${q(t.server + '/hello')}`), '200 stream hello')],
  ['http get!', async (t) => answer(await t.get(`/http/get?url=${q(t.server + '/hello')}`), '200 hello')],
  ['http get (Io twin)', async (t) => answer(await t.get(`/http/get_io?url=${q(t.server + '/hello')}`), '200 hello')],
  ['http get in Io.both! with Time.sleep', async (t) => {
    const r = await t.get(`/http/both?url=${q(t.server + '/hello')}`);
    answer(r, '200 hello');
    once(r);
  }],
  // PLAN.md 8d: the error map. The texts go to bench/README.md.
  // Local form: a throw, so `Network`. Edge form (`t.edge`, PLAN.md 11c, E17, E18, EP1): no throw, a Cloudflare error response,
  // so `Ok` with the status and the body: 403 `error code: 1003` (a closed port of 127.0.0.1), 530 `error code: 1016` (no DNS name).
  ['http 8d: a closed port is Network', async (t) => {
    const r = await t.get(`/http/get?url=${q('http://127.0.0.1:1/')}`);
    if (t.edge) ok(r.body === '403 error code: 1003', `got ${r.body}, want 403 error code: 1003 (edge form)`);
    else ok(r.body.startsWith('Network '), `got ${r.body}, want Network`);
    return r.body;
  }],
  ['http 8d: a host that does not exist is Network', async (t) => {
    const r = await t.get(`/http/get?url=${q('http://no-such-host.invalid/')}`);
    if (t.edge) ok(r.body === '530 error code: 1016', `got ${r.body}, want 530 error code: 1016 (edge form)`);
    else ok(r.body.startsWith('Network '), `got ${r.body}, want Network`);
    return r.body;
  }],
  ['http 8d: "not a url" is HttpErr with TypeError', async (t) => {
    const r = await t.get(`/http/get?url=${q('not a url')}`);
    ok(r.body.startsWith('HttpErr TypeError: '), `got ${r.body}, want HttpErr TypeError`);
    return r.body;
  }],
];
