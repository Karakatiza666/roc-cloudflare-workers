// `Http` (MODULES.md 4) and its error map (MC9, PLAN.md 8d): routes of conformance/HttpRoutes.roc. `t.server` is the
// local server of run.mjs. Each check gives the text that the route answered.
import { answer, eq, ok } from '../assert.mjs';

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
  ['http Request.post_json: JSON with the content type; a NaN is BadData and nothing is sent', async (t) => {
    const url = q(t.server + '/echo_json');
    answer(await t.get(`/http/post_json?url=${url}&v=pi`), '200 POST application/json {"name":"pi","r":0.5}');
    const bad = await t.get(`/http/post_json?url=${url}&v=nan`);
    ok(bad.status === 200 && bad.body.startsWith('BadData '), `got ${bad.body}`);
    eq(bad.awaits, 0, 'no crossing: nothing is sent');
  }],
  // `Http.cloudflare_error` (MODULES.md 4): status 400 or more, a body of at most 64 bytes that is `error code: <digits>`, a body of text or bytes.
  ['http cloudflare_error: 530 error code: 1016 and 403 error code: 1003 (bytes body of send!)', async (t) => {
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/cf530')}`), 'Ok({ code: 1016, status: 530 })');
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/cf403')}`), 'Ok({ code: 1003, status: 403 })');
  }],
  ['http cloudflare_error: a 404 with a normal body, and a status under 400, are NotCloudflareError', async (t) => {
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/nothing')}`), 'Err(NotCloudflareError)');
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/cf200')}`), 'Err(NotCloudflareError)');
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/hello')}`), 'Err(NotCloudflareError)');
  }],
  ['http cloudflare_error: a body of 64 bytes is read, a body of 76 bytes is not', async (t) => {
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/cf64')}`), 'Ok({ code: 1003, status: 403 })');
    answer(await t.get(`/http/cf_error?url=${q(t.server + '/cflong')}`), 'Err(NotCloudflareError)');
  }],
  ['http cloudflare_error: a stream body (open!) is NotCloudflareError', async (t) => {
    answer(await t.get(`/http/cf_error?open=1&url=${q(t.server + '/cf530')}`), 'Err(NotCloudflareError)');
  }],
  ['http cloudflare_error: a text body, the prefix, the digits and the status', async (t) => {
    const r = (status, body) => t.get(`/http/cf_error_text?status=${status}&body=${q(body)}`);
    answer(await r(530, 'error code: 1016'), 'Ok({ code: 1016, status: 530 })');
    answer(await r(403, 'error code: 1003\n'), 'Ok({ code: 1003, status: 403 })');
    answer(await r(400, 'error code: 7'), 'Ok({ code: 7, status: 400 })');
    answer(await r(399, 'error code: 1016'), 'Err(NotCloudflareError)');
    answer(await r(530, 'error code: 10x6'), 'Err(NotCloudflareError)');
    answer(await r(530, 'error code: '), 'Err(NotCloudflareError)');
    answer(await r(530, 'Error code: 1016'), 'Err(NotCloudflareError)');
    answer(await r(530, 'xerror code: 1016'), 'Err(NotCloudflareError)');
    answer(await r(403, `error code: 1003${' '.repeat(48)}`), 'Ok({ code: 1003, status: 403 })');
    answer(await r(403, `error code: 1003${' '.repeat(49)}`), 'Err(NotCloudflareError)');
  }],
];
