// `Assets` (MODULES.md 13): routes of conformance/AssetsRoutes.roc, on the local assets of Miniflare (the directory
// conformance/assets/). The worker runs first (`run_worker_first`), as an app that uses the binding does.
import { fileURLToPath } from 'node:url';
import { answer, eq, ok } from '../assert.mjs';

export const options = {
  assets: { directory: fileURLToPath(new URL('../assets', import.meta.url)), binding: 'ASSETS', run_worker_first: true, routerConfig: { has_user_worker: true } },
};

const HELLO = 'status=200 type=text/plain; charset=utf-8 body=hello-asset\n';

export const checks = [
  ['assets fetch!: a file, one wait (the body of the answer is read in a second one)', async (t) => {
    const r = await t.get('/assets/fetch?path=/hello.txt');
    answer(r, HELLO);
    eq(r.awaits, 2, 'js_await of fetch! and text!');
    const p = await t.get('/assets/pass?path=/hello.txt');
    answer(p, 'hello-asset\n');
    eq(p.awaits, 1, 'js_await of fetch! with the response passed on');
  }],
  ['assets fetch (Io twin)', async (t) => answer(await t.get('/assets/fetch_io?path=/hello.txt'), HELLO)],
  ['assets fetch!: a file that does not exist is an answer, not an error', async (t) => {
    const r = await t.get('/assets/fetch?path=/nope.txt');
    ok(r.status === 200 && r.body.startsWith('status=404 '), `got ${r.status} ${r.body}`);
  }],
  ['assets fetch!: the url of the request', async (t) => answer(await t.get('/assets/fetch?path=/index.html'), 'status=200 type=text/html; charset=utf-8 body=<h1>index</h1>\n')],
  ['assets fetch!: the method of the request (a POST is 405)', async (t) => {
    const r = await t.get('/assets/fetch?path=/hello.txt&method=POST');
    ok(r.status === 200 && r.body.startsWith('status=405 '), `got ${r.status} ${r.body}`);
  }],
  ['assets fetch!: the headers of the request (If-None-Match is 304)', async (t) => {
    const first = await t.mf.dispatchFetch('http://localhost/assets/pass?path=/hello.txt');
    const etag = first.headers.get('etag');
    ok(etag, 'the response has no etag');
    const r = await t.get(`/assets/fetch?path=/hello.txt&etag=${encodeURIComponent(etag)}`);
    ok(r.status === 200 && r.body.startsWith('status=304 '), `got ${r.status} ${r.body}`);
  }],
  ['assets fetch!: pass the response as it is (a stream), also the Io twin', async (t) => {
    for (const p of ['pass', 'pass_io']) {
      const r = await t.mf.dispatchFetch(`http://localhost/assets/${p}?path=/hello.txt`);
      eq(await r.text(), 'hello-asset\n', `${p} body`);
      eq(r.headers.get('content-type'), 'text/plain; charset=utf-8', `${p} content-type`);
      eq(r.status, 200, `${p} status`);
    }
  }],
  ['assets fetch!: a binding that is not in the config, and a url with no host, are AssetsErr', async (t) => {
    answer(await t.get('/assets/missing?path=/hello.txt'), 'AssetsErr TypeError');
    answer(await t.get('/assets/bad_url'), 'AssetsErr TypeError');
  }],
];
