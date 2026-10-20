// `R2` (MODULES.md 5.3): routes of conformance/R2Routes.roc, on the local R2 bucket `BUCKET` of Miniflare. Each check gives the
// text that the route answered. Miniflare differs from the edge in some places: the notes say where (PLAN.md 8c, for 11c).
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { answer, eq, ok } from '../assert.mjs';

export const options = { r2Buckets: ['BUCKET', 'TRACE'] };

const q = encodeURIComponent;
const MiB = 1024 * 1024;
// The multipart calls that the bucket `TRACE` recorded (conformance/bindings.js), as text.
const calls = async (t) => (await (await t.mf.dispatchFetch('http://localhost/__stub_calls')).json()).filter((c) => c.binding === 'TRACE');
const show = (c) => [c.method, ...c.args.filter((a) => typeof a === 'number')].join(' ');
// A writer stream of `bytes` bytes put on `TRACE`: the answer, and the multipart calls of this put.
const gen = async (t, key, bytes, extra = '') => {
  const n = (await calls(t)).length;
  const r = await t.get(`/r2/put_gen?key=${key}&bytes=${bytes}&trace=1${extra}`);
  return { r, calls: (await calls(t)).slice(n).map(show) };
};
// The etag of a key, from the route `head`.
async function etagOf(t, key) {
  const r = await t.get(`/r2/head?key=${key}`);
  const m = /etag=([0-9a-f]+)/.exec(r.body);
  ok(m, `no etag in ${r.body}`);
  return m[1];
}
// A GET of a route with request headers: the status, the headers (a plain object, with no `mf-content-encoding` of Miniflare), the text.
async function hit(t, path, headers = {}) {
  const res = await t.mf.dispatchFetch(`http://localhost${path}`, { headers });
  const text = new TextDecoder().decode(await res.arrayBuffer());
  const out = {};
  for (const [k, v] of [...res.headers].sort()) {
    if (['mf-content-encoding', 'content-length', 'date', 'x-waits', 'x-awaits', 'x-calls', 'x-ms', 'transfer-encoding'].includes(k)) continue;
    out[k] = v;
  }
  return { status: res.status, headers: out, text };
}
const put = (t, key, text) => t.get(`/r2/put?key=${key}&text=${q(text)}`);
// PLAN.md EP10: a multipart upload that is not complete keeps a real bucket from a delete, and nothing else knows its id.
// `uploads` runs `body(open)`; `open(upload)` notes an upload, and each noted upload is aborted at the end, also when a
// check fails. An upload that is complete or aborted gives `Err Infra(R2Err(...))` at the abort: that is no error here.
async function uploads(t, body) {
  const noted = [];
  const abortAll = async () => {
    for (const upload of noted) await t.get(`/r2/mp_abort?upload=${q(JSON.stringify(upload))}`).catch(() => {});
  };
  try {
    return await body((upload) => (noted.push(upload), upload));
  } finally {
    await abortAll();
  }
}

export const checks = [
  ['r2 put!', async (t) => {
    const r = await put(t, 'put1', 'hello');
    ok(r.status === 200 && r.body.startsWith('Ok key=put1 size=5 etag=5d41402abc4b2a76b9719d911017c592 cc=none') && r.body.includes('md5=16'), `got ${r.body}`);
    eq(r.waits, 1, 'waits');
    eq(Buffer.from(await (await (await t.mf.getR2Bucket('BUCKET')).get('put1')).arrayBuffer()).toString(), 'hello', 'the stored bytes');
  }],
  ['r2 put (Io twin)', async (t) => {
    const r = await t.get('/r2/put_io?key=put2&text=hi');
    ok(r.body.startsWith('Ok key=put2 size=2 '), `got ${r.body}`);
  }],
  ['r2 get!', async (t) => {
    await put(t, 'get1', 'hello');
    // One wait for the get, one more for the body (a stream, API.md RS3).
    const r = await t.get('/r2/get?key=get1');
    answer(r, 'Ok size=5 range=none text=hello');
    eq(r.waits, 2, 'waits');
  }],
  ['r2 get (Io twin)', async (t) => answer(await t.get('/r2/get_io?key=get1'), 'Ok size=5 range=none text=hello')],
  // OP7: `Fields` of the `null` result is `undefined`, so a missing key is `NotFound` with no branch.
  ['r2 get! of a missing key is NotFound', async (t) => answer(await t.get('/r2/get?key=missing'), 'Err NotFound')],
  ['r2 head! of a missing key is NotFound', async (t) => answer(await t.get('/r2/head?key=missing'), 'Err NotFound')],
  ['r2 head!', async (t) => {
    const r = await t.get('/r2/head?key=get1');
    ok(r.body.startsWith('Ok key=get1 size=5 '), `got ${r.body}`);
    eq(r.waits, 1, 'waits');
  }],
  ['r2 head (Io twin)', async (t) => ok((await t.get('/r2/head_io?key=get1')).body.startsWith('Ok key=get1 size=5 '), 'head_io')],
  ['r2 put_with! only_if: a wrong etag_matches is PreconditionFailed', async (t) => {
    await put(t, 'cas', 'v1');
    answer(await t.get('/r2/put_with?key=cas&text=v2&etag=wrong'), 'Err PreconditionFailed');
    answer(await t.get('/r2/head?key=cas').then((r) => ({ ...r, body: r.body.replace(/ etag=\w+/, '') })), 'Ok key=cas size=2 cc=none type=none custom= md5=16 sha256=none');
    // The right etag swaps.
    const etag = await etagOf(t, 'cas');
    ok((await t.get(`/r2/put_with?key=cas&text=v3&etag=${etag}`)).body.startsWith('Ok key=cas size=2 '), 'the right etag');
  }],
  ['r2 put_with (Io twin) only_if', async (t) => answer(await t.get('/r2/put_with_io?key=cas&text=v2&etag=wrong'), 'Err PreconditionFailed')],
  ['r2 put_with! absent: a key that exists is PreconditionFailed', async (t) => {
    await put(t, 'abs', 'x');
    answer(await t.get('/r2/put_with?key=abs&text=y&absent=1'), 'Err PreconditionFailed');
    // A new key is written. Edge part (11c): the wildcard is in the workerd source only.
    ok((await t.get('/r2/put_with?key=abs-new&text=y&absent=1')).body.startsWith('Ok key=abs-new '), 'a new key');
  }],
  // Two fields at once. Miniflare: a right etag_matches makes uploaded_before pass (the HTTP rule of If-Match), so the plan's
  // pair (a right etag and an uploaded_before_ms in the past) is Ok here; the edge result is for 11c. The pair that Miniflare
  // does fail is a right etag and an uploaded_after_ms in the future.
  ['r2 put_with! only_if with two fields', async (t) => {
    await put(t, 'two', 'x');
    const etag = await etagOf(t, 'two');
    const future = Date.now() + 3_600_000;
    answer(await t.get(`/r2/put_with?key=two&text=y&etag=${etag}&after=${future}`), 'Err PreconditionFailed');
    const r = await t.get(`/r2/put_with?key=two&text=z&etag=${etag}&before=${Date.now() - 3_600_000}`);
    return `etag and before in the past: ${r.body.startsWith('Ok ') ? 'Ok (Miniflare)' : r.body}`;
  }],
  ['r2 get_with! only_if: a wrong etag_matches is PreconditionFailed', async (t) => {
    answer(await t.get('/r2/get_with?key=get1&etag=wrong'), 'Err PreconditionFailed');
    const etag = await etagOf(t, 'get1');
    answer(await t.get(`/r2/get_with?key=get1&etag=${etag}`), 'Ok size=5 range=none text=hello');
  }],
  ['r2 get_with! range From', async (t) => {
    answer(await t.get('/r2/get_with?key=get1&offset=2&len=3'), 'Ok size=5 range=from 2 len 3 text=llo');
    answer(await t.get('/r2/get_with_io?key=get1&offset=2&len=3'), 'Ok size=5 range=from 2 len 3 text=llo');
  }],
  ['r2 get_with! range Suffix', async (t) => answer(await t.get('/r2/get_with?key=get1&suffix=2'), 'Ok size=5 range=from 3 len 2 text=lo')],
  // ---- Conditional headers, to_response, respond! (MODULES.md 5.3) ----
  // The object has all HTTP metadata, so each header of `to_response` shows. `hit` gives the status, the headers
  // (without `mf-content-encoding` of Miniflare) and the bytes.
  ['r2 to_response: 200, the metadata and etag, a missing metadata field is not set', async (t) => {
    const bucket = await t.mf.getR2Bucket('BUCKET');
    const expires = new Date('2030-01-02T03:04:05Z');
    await bucket.put('cond1', 'hello world', { httpMetadata: { contentType: 'text/plain', contentLanguage: 'en', contentDisposition: 'inline', cacheControl: 'max-age=60', cacheExpiry: expires } });
    const etag = await etagOf(t, 'cond1');
    const full = await hit(t, '/r2/to_response?key=cond1');
    eq(full.status, 200, 'status');
    eq(full.text, 'hello world', 'body');
    eq(JSON.stringify(full.headers), JSON.stringify({
      'cache-control': 'max-age=60', 'content-disposition': 'inline', 'content-language': 'en', 'content-type': 'text/plain', etag: `"${etag}"`, expires: 'Wed, 02 Jan 2030 03:04:05 GMT',
    }), 'headers');
    // No metadata: only etag, and no content-type header from the object.
    await bucket.put('cond2', 'x');
    const bare = await hit(t, '/r2/to_response?key=cond2');
    eq(bare.status, 200, 'bare status');
    for (const name of ['cache-control', 'content-disposition', 'content-language', 'expires']) ok(!(name in bare.headers), `${name} is set: ${JSON.stringify(bare.headers)}`);
    ok('etag' in bare.headers, 'etag');
    const none = await t.get('/r2/to_response?key=missing-key');
    ok(none.status === 404 && none.body === 'Err(NotFound)' || none.body.includes('NotFound'), `got ${none.status} ${none.body}`);
  }],
  ['r2 respond!: 200 with the metadata, etag and accept-ranges', async (t) => {
    const etag = await etagOf(t, 'cond1');
    for (const path of ['/r2/respond?key=cond1', '/r2/respond_io?key=cond1']) {
      const r = await hit(t, path);
      eq(r.status, 200, `${path} status`);
      eq(r.text, 'hello world', `${path} body`);
      eq(JSON.stringify(r.headers), JSON.stringify({
        'accept-ranges': 'bytes', 'cache-control': 'max-age=60', 'content-disposition': 'inline', 'content-language': 'en', 'content-type': 'text/plain', etag: `"${etag}"`, expires: 'Wed, 02 Jan 2030 03:04:05 GMT',
      }), `${path} headers`);
    }
  }],
  ['r2 respond!: a key that is not there is 404 "Not found"', async (t) => {
    const r = await hit(t, '/r2/respond?key=nothing-here');
    eq(r.status, 404, 'status');
    eq(r.text, 'Not found', 'body');
  }],
  ['r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body', async (t) => {
    const etag = await etagOf(t, 'cond1');
    for (const value of [`"${etag}"`, `W/"${etag}"`, '*']) {
      const r = await hit(t, '/r2/respond?key=cond1', { 'if-none-match': value });
      eq(r.status, 304, `status for ${value}`);
      eq(r.text, '', `body for ${value}`);
      eq(JSON.stringify(r.headers), JSON.stringify({ 'cache-control': 'max-age=60', etag: `"${etag}"`, expires: 'Wed, 02 Jan 2030 03:04:05 GMT' }), `headers for ${value}`);
    }
    // Another etag is a normal 200.
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-none-match': '"other"' })).status, 200, 'another etag');
  }],
  ['r2 respond!: If-Modified-Since after the upload is 304, before it is 200', async (t) => {
    const after = new Date(Date.now() + 3_600_000).toUTCString();
    const before = new Date(Date.now() - 3_600_000).toUTCString();
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-modified-since': after })).status, 304, 'after');
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-modified-since': before })).status, 200, 'before');
  }],
  ['r2 respond!: If-Match with another etag is 412 (not 304), with the right etag is 200', async (t) => {
    const etag = await etagOf(t, 'cond1');
    const bad = await hit(t, '/r2/respond?key=cond1', { 'if-match': '"other"' });
    eq(bad.status, 412, 'status');
    eq(bad.text, '', 'body');
    eq(JSON.stringify(bad.headers), JSON.stringify({ 'cache-control': 'max-age=60', etag: `"${etag}"`, expires: 'Wed, 02 Jan 2030 03:04:05 GMT' }), 'headers');
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-match': `"${etag}"` })).status, 200, 'the right etag');
  }],
  ['r2 respond!: If-Unmodified-Since before the upload is 412, after it is 200', async (t) => {
    const after = new Date(Date.now() + 3_600_000).toUTCString();
    const before = new Date(Date.now() - 3_600_000).toUTCString();
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-unmodified-since': before })).status, 412, 'before');
    eq((await hit(t, '/r2/respond?key=cond1', { 'if-unmodified-since': after })).status, 200, 'after');
  }],
  ['r2 respond!: one range is 206 with content-range and the bytes (a-b, a-, -n, past the end)', async (t) => {
    const etag = await etagOf(t, 'cond1');
    const cases = [
      ['bytes=2-4', 'bytes 2-4/11', 'llo'],
      ['bytes=6-', 'bytes 6-10/11', 'world'],
      ['bytes=-5', 'bytes 6-10/11', 'world'],
      ['bytes=0-0', 'bytes 0-0/11', 'h'],
      ['bytes=8-100', 'bytes 8-10/11', 'rld'],
      ['bytes=-100', 'bytes 0-10/11', 'hello world'],
    ];
    for (const [range, cr, text] of cases) {
      const r = await hit(t, '/r2/respond?key=cond1', { range });
      eq(r.status, 206, `${range} status`);
      eq(r.text, text, `${range} body`);
      eq(r.headers['content-range'], cr, `${range} content-range`);
      eq(r.headers['accept-ranges'], 'bytes', `${range} accept-ranges`);
      eq(r.headers.etag, `"${etag}"`, `${range} etag`);
    }
    eq((await hit(t, '/r2/respond_io?key=cond1', { range: 'bytes=2-4' })).text, 'llo', 'the Io twin');
  }],
  ['r2 respond!: a range after the end is 416 (R2 error 10039)', async (t) => {
    for (const range of ['bytes=11-', 'bytes=20-30']) {
      const r = await hit(t, '/r2/respond?key=cond1', { range });
      eq(r.status, 416, `${range} status`);
      eq(r.headers['content-range'], 'bytes */11', `${range} content-range`);
    }
  }],
  ['r2 respond!: more than one range, a wrong range and If-Range give 200 with the whole object', async (t) => {
    for (const h of [{ range: 'bytes=0-1,4-5' }, { range: 'bytes=5-2' }, { range: 'items=0-1' }, { range: 'bytes=2-4', 'if-range': '"x"' }]) {
      const r = await hit(t, '/r2/respond?key=cond1', h);
      eq(r.status, 200, `${JSON.stringify(h)} status`);
      eq(r.text, 'hello world', `${JSON.stringify(h)} body`);
      ok(!('content-range' in r.headers), `${JSON.stringify(h)} has content-range`);
    }
  }],
  ['r2 respond!: a range with a failed condition is 304, not 206', async (t) => {
    const etag = await etagOf(t, 'cond1');
    eq((await hit(t, '/r2/respond?key=cond1', { range: 'bytes=2-4', 'if-none-match': `"${etag}"` })).status, 304, 'status');
  }],
  ['r2 get_with! of R2.from_headers: a failed If-Match is PreconditionFailed, a right one and no header are Ok', async (t) => {
    const etag = await etagOf(t, 'cond1');
    answer(await t.get('/r2/get_cond?key=cond1', { headers: { 'if-match': '"other"' } }), 'Err PreconditionFailed');
    answer(await t.get('/r2/get_cond?key=cond1', { headers: { 'if-none-match': `"${etag}"` } }), 'Err PreconditionFailed');
    answer(await t.get('/r2/get_cond?key=cond1', { headers: { 'if-none-match': `W/"${etag}"` } }), 'Err PreconditionFailed');
    answer(await t.get('/r2/get_cond?key=cond1', { headers: { 'if-match': `"${etag}"` } }), 'Ok size=11 range=none text=hello world');
    // A weak etag in If-Match is PreconditionFailed in Miniflare (the strong comparison of HTTP): not checked, see the report.
    answer(await t.get('/r2/get_cond?key=cond1'), 'Ok size=11 range=none text=hello world');
    // Only the four conditional headers go to R2: other headers change nothing.
    answer(await t.get('/r2/get_cond?key=cond1', { headers: { 'x-other': '1', range: 'bytes=0-1' } }), 'Ok size=11 range=none text=hello world');
  }],
  ['r2 put_with! of a Body.writer! stream with no length_bytes stores the bytes', async (t) => {
    const r = await t.get('/r2/put_stream?key=ws1');
    ok(r.body.startsWith('Ok key=ws1 size=11 '), `got ${r.body}`);
    eq(await (await (await t.mf.getR2Bucket('BUCKET')).get('ws1')).text(), 'hello world', 'the stored bytes');
  }],
  // ---- 8h wave B: a writer stream with no length (`pf.r2put`, MODULES.md 5.3). The bucket `TRACE` records its multipart calls. ----
  ['r2 put! of a writer stream of 1 KiB with no length is one put (no multipart upload), content type kept', async (t) => {
    const { r, calls } = await gen(t, 'g1k', 1024);
    ok(r.body.startsWith('Ok key=g1k size=1024 '), `got ${r.body}`);
    ok(!/etag=\S*-\d/.test(r.body), `the etag is of a multipart upload: ${r.body}`);
    ok(r.body.includes(' type=text/x-big '), `got ${r.body}`);
    eq(JSON.stringify(calls), '[]', 'the multipart calls');
    const o = await (await t.mf.getR2Bucket('TRACE')).get('g1k');
    eq(o.size, 1024, 'size');
    eq(o.httpMetadata.contentType, 'text/x-big', 'content type');
  }],
  ['r2 put! of a writer stream of exactly 5 MiB with no length is one put', async (t) => {
    const { r, calls } = await gen(t, 'g5m', 5 * MiB);
    ok(r.body.startsWith(`Ok key=g5m size=${5 * MiB} `), `got ${r.body}`);
    eq(JSON.stringify(calls), '[]', 'the multipart calls');
  }],
  ['r2 put! of a writer stream of 11 MiB with no length is a multipart upload of 3 parts: size exact, content type kept', async (t) => {
    const { r, calls } = await gen(t, 'g11m', 11 * MiB);
    ok(r.body.startsWith(`Ok key=g11m size=${11 * MiB} `), `got ${r.body}`);
    ok(/etag=\S+-3 /.test(r.body), `the etag does not end in -3: ${r.body}`);
    ok(r.body.includes(' type=text/x-big '), `the content type of the result: ${r.body}`);
    eq(JSON.stringify(calls), JSON.stringify([
      'createMultipartUpload', 'uploadPart 1 5242880', 'uploadPart 2 5242880', 'uploadPart 3 1048576', 'complete',
    ]), 'the multipart calls');
    const o = await (await t.mf.getR2Bucket('TRACE')).get('g11m');
    const b = new Uint8Array(await o.arrayBuffer());
    eq(b.length, 11 * MiB, 'the stored size');
    eq(o.httpMetadata.contentType, 'text/x-big', 'the content type of the object');
    // The bytes of each 1 MiB chunk: `A` + its number. A part border in the wrong place or a lost chunk moves them.
    for (let i = 0; i < 11; i++) eq(b[i * MiB] === 65 + i && b[(i + 1) * MiB - 1] === 65 + i, true, `chunk ${i}`);
  }],
  ['r2 put! of a writer stream of 5 MiB and 1 byte is two parts (5 MiB, 1 byte)', async (t) => {
    const { r, calls } = await gen(t, 'g5m1', 5 * MiB + 1);
    ok(r.body.startsWith(`Ok key=g5m1 size=${5 * MiB + 1} `) && /etag=\S+-2 /.test(r.body), `got ${r.body}`);
    eq(JSON.stringify(calls), JSON.stringify(['createMultipartUpload', 'uploadPart 1 5242880', 'uploadPart 2 1', 'complete']), 'the multipart calls');
  }],
  ['r2 put! of a stream that errors in the middle aborts the upload: no object, no complete', async (t) => {
    const n = (await calls(t)).length;
    const r = await t.get(`/r2/put_broken?key=gbroken&from=${q(`${t.server}/broken`)}`);
    ok(r.body.startsWith('Err Infra(R2Err('), `got ${r.body}`);
    eq(await (await t.mf.getR2Bucket('TRACE')).get('gbroken'), null, 'the object');
    let got = [];
    for (let i = 0; i < 40; i++) {
      got = (await calls(t)).slice(n).map(show);
      if (got.includes('abort')) break;
      await new Promise((res) => setTimeout(res, 50));
    }
    eq(JSON.stringify(got), JSON.stringify(['createMultipartUpload', 'uploadPart 1 5242880', 'abort']), 'the multipart calls');
  }],
  ['r2 put_with! only_if with a stream of unknown length over 5 MiB is R2Err (no upload, no object)', async (t) => {
    const { r, calls: c } = await gen(t, 'gcond', 6 * MiB, '&etag=anything');
    ok(r.body.startsWith('Err Infra(R2Err(') && r.body.includes('only_if'), `got ${r.body}`);
    eq(JSON.stringify(c), '[]', 'the multipart calls');
    eq(await (await t.mf.getR2Bucket('TRACE')).get('gcond'), null, 'the object');
  }],
  ['r2 put_with! only_if with a stream of unknown length up to 5 MiB is one put with the condition', async (t) => {
    const { r } = await gen(t, 'gcond2', 1024, '&absent=1');
    ok(r.body.startsWith('Ok key=gcond2 size=1024 '), `got ${r.body}`);
    const again = await gen(t, 'gcond2', 1024, '&absent=1');
    ok(again.r.body.startsWith('Err PreconditionFailed'), `the second put: ${again.r.body}`);
  }],
  ['r2 put_with! of a stream with length_bytes stores the bytes', async (t) => {
    const r = await t.get('/r2/put_stream?key=ws2&len=11');
    ok(r.body.startsWith('Ok key=ws2 size=11 '), `got ${r.body}`);
    eq(await (await (await t.mf.getR2Bucket('BUCKET')).get('ws2')).text(), 'hello world', 'the stored bytes');
  }],
  ['r2 put_with! http: head! has it, list! has none, list! with include has it', async (t) => {
    ok((await t.get('/r2/put_with?key=http1&text=abc&cc=max-age%3D60')).body.startsWith('Ok key=http1 size=3 '), 'put');
    ok((await t.get('/r2/head?key=http1')).body.includes(' cc=max-age=60 '), 'head has cache_control');
    answer(await t.get('/r2/list?prefix=http1'), 'Ok objects=[http1:none:] prefixes=[] next=Done');
    answer(await t.get('/r2/list?prefix=http1&include=http'), 'Ok objects=[http1:max-age=60:] prefixes=[] next=Done');
    answer(await t.get('/r2/list_io?prefix=http1&include=http'), 'Ok objects=[http1:max-age=60:] prefixes=[] next=Done');
  }],
  ['r2 put_with! custom, list! include Custom', async (t) => {
    ok((await t.get('/r2/put_with?key=cust1&text=abc&custom=origin:test')).body.includes(' custom=origin=test '), 'put and custom');
    answer(await t.get('/r2/list?prefix=cust1&include=custom'), 'Ok objects=[cust1:none:origin=test] prefixes=[] next=Done');
    answer(await t.get('/r2/list?prefix=cust1'), 'Ok objects=[cust1:none:] prefixes=[] next=Done');
  }],
  // Edge part (11c): `start_after` is in the workerd source only.
  ['r2 list! start_after', async (t) => {
    for (const k of ['sa/a', 'sa/b', 'sa/c']) await put(t, k.replace('/', '%2F'), 'x');
    answer(await t.get('/r2/list?prefix=sa/&start_after=sa/b'), 'Ok objects=[sa/c:none:] prefixes=[] next=Done');
    answer(await t.get('/r2/list?prefix=sa/'), 'Ok objects=[sa/a:none: sa/b:none: sa/c:none:] prefixes=[] next=Done');
  }],
  ['r2 list! limit, cursor, delimiter', async (t) => {
    for (const k of ['ls/a/1', 'ls/a/2', 'ls/b']) await put(t, k.replaceAll('/', '%2F'), 'x');
    answer(await t.get('/r2/list?prefix=ls/&delimiter=/'), 'Ok objects=[ls/b:none:] prefixes=[ls/a/] next=Done');
    const r = await t.get('/r2/list?prefix=ls/&limit=1');
    ok(r.body.includes('next=More'), `got ${r.body}`);
  }],
  ['r2 put_with! checksum: a wrong Sha256 is R2Err, the right one is in meta.checksums', async (t) => {
    const bad = await t.get('/r2/put_with?key=sum1&text=abc&sha=wrong');
    ok(bad.body.startsWith('Err Infra(R2Err(') && bad.body.includes('SHA-256 checksum'), `got ${bad.body}`);
    const good = await t.get('/r2/put_with?key=sum2&text=abc&sha=right');
    ok(good.body.includes('sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'), `got ${good.body}`);
  }],
  // Miniflare gives each hash of an object. The edge gives MD5 and the hash that the put got (Cloudflare docs): 11c.
  ['r2 put! with no checksum has an MD5', async (t) => {
    const r = await put(t, 'md5', 'hello');
    ok(r.body.includes(' md5=16 '), `got ${r.body}`);
  }],
  ['r2 delete!', async (t) => {
    await put(t, 'del1', 'x');
    await put(t, 'del2', 'x');
    answer(await t.get('/r2/delete?keys=del1,del2'), 'Ok deleted');
    answer(await t.get('/r2/head?key=del1'), 'Err NotFound');
    await put(t, 'del3', 'x');
    answer(await t.get('/r2/delete_io?keys=del3'), 'Ok deleted');
    answer(await t.get('/r2/head?key=del3'), 'Err NotFound');
  }],
  // Multipart (MODULES.md 5.3): three requests, the upload as JSON between them.
  ['r2 multipart: create, upload_part, complete in three requests', (t) => uploads(t, async (open) => {
    const key = 'mp1';
    const r1 = await t.get(`/r2/mp_create?key=${key}`);
    ok(r1.status === 200 && r1.body.startsWith('{"upload":'), `request 1: ${r1.body.slice(0, 200)}`);
    const { upload, part: part1 } = JSON.parse(r1.body);
    open(upload);
    eq(upload.key, key, 'the key of the upload');
    eq(upload.bucket, 'BUCKET', 'the bucket of the upload');
    eq(part1.part_number, 1, 'part 1');
    const r2 = await t.get(`/r2/mp_part?upload=${q(JSON.stringify(upload))}`);
    ok(r2.status === 200 && r2.body.startsWith('{'), `request 2: ${r2.body.slice(0, 200)}`);
    const part2 = JSON.parse(r2.body);
    eq(part2.part_number, 2, 'part 2');
    const res = await t.mf.dispatchFetch(`http://localhost/r2/mp_complete?upload=${q(JSON.stringify(upload))}&parts=${q(JSON.stringify([part1, part2]))}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    eq(res.status, 200, 'request 3 status');
    ok(bytes.length === 5 * MiB + 1024, `request 3: ${bytes.length} bytes: ${Buffer.from(bytes.slice(0, 200)).toString()}`);
    ok(bytes.subarray(0, 5 * MiB).every((b) => b === 65), 'the bytes of part 1');
    ok(bytes.subarray(5 * MiB).every((b) => b === 66), 'the bytes of part 2');
    return `${bytes.length} bytes`;
  })],
  ['r2 multipart (Io twins): create, upload_part, complete', (t) => uploads(t, async (open) => {
    const r1 = await t.get('/r2/mp_create_io?key=mp2');
    const { upload, part: part1 } = JSON.parse(r1.body);
    open(upload);
    const part2 = JSON.parse((await t.get(`/r2/mp_part_io?upload=${q(JSON.stringify(upload))}`)).body);
    const res = await t.mf.dispatchFetch(`http://localhost/r2/mp_complete_io?upload=${q(JSON.stringify(upload))}&parts=${q(JSON.stringify([part1, part2]))}`);
    eq((await res.arrayBuffer()).byteLength, 5 * MiB + 1024, 'the object');
  })],
  ['r2 multipart: resume_multipart_upload needs no crossing and abort! stops the upload', (t) => uploads(t, async (open) => {
    const r = await t.get('/r2/mp_resume?key=k&id=abc');
    answer(r, '{"bucket":"BUCKET","key":"k","upload_id":"abc"}');
    eq(r.waits, 0, 'waits');
    const upload = open(JSON.parse((await t.get(`/r2/mp_create?key=mp3`)).body).upload);
    answer(await t.get(`/r2/mp_abort?upload=${q(JSON.stringify(upload))}`), 'Ok aborted');
    // A part after the abort is R2Err.
    ok((await t.get(`/r2/mp_part?upload=${q(JSON.stringify(upload))}`)).body.startsWith('Err Infra(R2Err('), 'a part after the abort');
    const up2 = open(JSON.parse((await t.get('/r2/mp_create_io?key=mp4')).body).upload);
    answer(await t.get(`/r2/mp_abort_io?upload=${q(JSON.stringify(up2))}`), 'Ok aborted');
  })],
  ['r2 multipart: upload_part_with! length_bytes, create_multipart_upload_with!', (t) => uploads(t, async (open) => {
    const { upload } = JSON.parse((await t.get('/r2/mp_create?key=mp5')).body);
    open(upload);
    const partNumber = async (path) => JSON.parse((await t.get(`${path}?upload=${q(JSON.stringify(upload))}&len=1024`)).body).part_number;
    eq(await partNumber('/r2/mp_part_with'), 2, 'upload_part_with!');
    eq(await partNumber('/r2/mp_part_with_io'), 2, 'upload_part_with (twin)');
    // Local form: the result of `complete!` has `http` and `custom`. Edge form (`t.edge`, PLAN.md 11c, E28, EP5): it has none, and
    // `head!` of the key has them.
    const meta = async (path, key) => {
      const r = await t.get(path);
      if (!t.edge) return r;
      ok(r.body.startsWith(`Ok key=${key} size=9 `), `got ${r.body}`);
      return t.get(`/r2/head?key=${key}`);
    };
    const w = await meta('/r2/mp_with?key=mp6', 'mp6');
    ok(w.body.startsWith('Ok key=mp6 size=9 ') && w.body.includes(' cc=max-age=30 ') && w.body.includes(' custom=origin=mp '), `got ${w.body}`);
    ok((await meta('/r2/mp_with_io?key=mp7', 'mp7')).body.includes(' cc=max-age=30 '), 'the twin');
  })],
  // PLAN.md EP10: the helper `uploads` aborts the upload of a check that fails.
  ['r2 multipart: an upload of a check that fails is aborted', async (t) => {
    let upload;
    const failed = await uploads(t, async (open) => {
      upload = open(JSON.parse((await t.get('/r2/mp_create?key=mpf')).body).upload);
      throw new Error('a check fails');
    }).then(() => null, (e) => e.message);
    eq(failed, 'a check fails', 'the throw of the check');
    ok((await t.get(`/r2/mp_part?upload=${q(JSON.stringify(upload))}`)).body.startsWith('Err Infra(R2Err('), 'the upload is still open');
  }],
  // PLAN.md EP10: a route that cannot finish its upload aborts it, because the caller has no upload id. Part number 10001 is
  // refused, and a wrong etag makes `complete!` fail. The check after these ones counts the open uploads.
  ['r2 multipart: a route with a part or a complete that fails aborts its upload', async (t) => {
    for (const path of ['/r2/mp_create?key=mpb1&part=10001', '/r2/mp_create_io?key=mpb2&part=10001', '/r2/mp_with?key=mpb3&part=10001', '/r2/mp_with?key=mpb4&etag=wrong', '/r2/mp_with_io?key=mpb5&etag=wrong']) {
      const r = await t.get(path);
      ok(r.status === 200 && r.body.startsWith('Err Infra(R2Err('), `${path}: got ${r.status} ${r.body.slice(0, 200)}`);
    }
  }],
  // PLAN.md EP10: no upload of the checks above is open. Miniflare keeps the bucket on disk in its temp dir (`run.mjs` sets
  // TMPDIR to the dir of the run): the SQLite file in the dir `r2` has the table `_mf_multipart_uploads` (state 0: in
  // progress, 1: complete, 2: aborted; Miniflare, `bucket.worker.js`).
  ['r2 multipart: no upload is open after the checks', async (t) => {
    // Local only: the file of the bucket. On the edge `uploads` has aborted each upload, and a delete of the bucket shows it.
    if (t.edge) throw new Error('MF-ONLY: the SQLite file of the local bucket');
    const root = process.env.TMPDIR;
    const files = readdirSync(root, { recursive: true }).filter((f) => /(^|\/)r2\/.*\.sqlite$/.test(f));
    ok(files.length > 0, `no SQLite file of an r2 bucket in ${root}`);
    const states = [];
    for (const f of files) {
      const db = new DatabaseSync(join(root, f), { readOnly: true });
      try {
        states.push(...db.prepare('SELECT state FROM _mf_multipart_uploads').all().map((r) => r.state));
      } catch (e) {
        if (!String(e.message).includes('no such table')) throw e;
      } finally {
        db.close();
      }
    }
    const count = (n) => states.filter((s) => s === n).length;
    ok(count(1) >= 4, `the checks made at least 4 complete uploads: ${JSON.stringify(states)}`);
    eq(count(0), 0, `open uploads (states ${JSON.stringify(states)})`);
    return `uploads: ${count(1)} complete, ${count(2)} aborted, ${count(0)} open`;
  }],
  // 10a with R2: an object of 50 MB through get! to the response, as a stream. wasm memory grows by less than 1 MB.
  ['r2 10a: a 50 MB object through get! to the response, wasm memory grows by less than 1 MB', async (t) => {
    const size = 50 * MiB;
    const bucket = await t.mf.getR2Bucket('BUCKET');
    const data = new Uint8Array(size);
    for (let i = 0; i < size; i += 4096) data[i] = i / 4096 % 251;
    await bucket.put('big', data);
    const mem = async () => Number((await t.mf.dispatchFetch('http://localhost/__mem').then((r) => r.text())));
    await t.get('/r2/head?key=big');
    const before = await mem();
    const res = await t.mf.dispatchFetch('http://localhost/r2/big?key=big');
    const got = new Uint8Array(await res.arrayBuffer());
    const after = await mem();
    eq(got.length, size, 'the size of the answer');
    ok(got.every((b, i) => b === data[i]), 'the bytes differ');
    ok(after - before < MiB, `wasm memory grew by ${after - before} bytes`);
    return `grew by ${after - before} bytes`;
  }],
];
