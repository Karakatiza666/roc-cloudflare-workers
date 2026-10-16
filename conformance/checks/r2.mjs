// `R2` (MODULES.md 5.3): routes of conformance/R2Routes.roc, on the local R2 bucket `BUCKET` of Miniflare. Each check gives the
// text that the route answered. Miniflare differs from the edge in some places: the notes say where (PLAN.md 8c, for 11c).
import { answer, eq, ok } from '../assert.mjs';

export const options = { r2Buckets: ['BUCKET'] };

const q = encodeURIComponent;
const MiB = 1024 * 1024;
// The etag of a key, from the route `head`.
async function etagOf(t, key) {
  const r = await t.get(`/r2/head?key=${key}`);
  const m = /etag=([0-9a-f]+)/.exec(r.body);
  ok(m, `no etag in ${r.body}`);
  return m[1];
}
const put = (t, key, text) => t.get(`/r2/put?key=${key}&text=${q(text)}`);

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
  ['r2 put_with! of a Body.writer! stream is R2Err with "known length"', async (t) => {
    const r = await t.get('/r2/put_stream?key=ws1');
    ok(r.body.startsWith('Err R2Err(') && r.body.includes('known length'), `got ${r.body}`);
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
    ok(bad.body.startsWith('Err R2Err(') && bad.body.includes('SHA-256 checksum'), `got ${bad.body}`);
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
  ['r2 multipart: create, upload_part, complete in three requests', async (t) => {
    const key = 'mp1';
    const r1 = await t.get(`/r2/mp_create?key=${key}`);
    ok(r1.status === 200 && r1.body.startsWith('{"upload":'), `request 1: ${r1.body.slice(0, 200)}`);
    const { upload, part: part1 } = JSON.parse(r1.body);
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
  }],
  ['r2 multipart (Io twins): create, upload_part, complete', async (t) => {
    const r1 = await t.get('/r2/mp_create_io?key=mp2');
    const { upload, part: part1 } = JSON.parse(r1.body);
    const part2 = JSON.parse((await t.get(`/r2/mp_part_io?upload=${q(JSON.stringify(upload))}`)).body);
    const res = await t.mf.dispatchFetch(`http://localhost/r2/mp_complete_io?upload=${q(JSON.stringify(upload))}&parts=${q(JSON.stringify([part1, part2]))}`);
    eq((await res.arrayBuffer()).byteLength, 5 * MiB + 1024, 'the object');
  }],
  ['r2 multipart: resume_multipart_upload needs no crossing and abort! stops the upload', async (t) => {
    const r = await t.get('/r2/mp_resume?key=k&id=abc');
    answer(r, '{"bucket":"BUCKET","key":"k","upload_id":"abc"}');
    eq(r.waits, 0, 'waits');
    const { upload } = JSON.parse((await t.get('/r2/mp_create?key=mp3')).body);
    answer(await t.get(`/r2/mp_abort?upload=${q(JSON.stringify(upload))}`), 'Ok aborted');
    // A part after the abort is R2Err.
    ok((await t.get(`/r2/mp_part?upload=${q(JSON.stringify(upload))}`)).body.startsWith('Err R2Err('), 'a part after the abort');
    const { upload: up2 } = JSON.parse((await t.get('/r2/mp_create_io?key=mp4')).body);
    answer(await t.get(`/r2/mp_abort_io?upload=${q(JSON.stringify(up2))}`), 'Ok aborted');
  }],
  ['r2 multipart: upload_part_with! length_bytes, create_multipart_upload_with!', async (t) => {
    const { upload } = JSON.parse((await t.get('/r2/mp_create?key=mp5')).body);
    const partNumber = async (path) => JSON.parse((await t.get(`${path}?upload=${q(JSON.stringify(upload))}&len=1024`)).body).part_number;
    eq(await partNumber('/r2/mp_part_with'), 2, 'upload_part_with!');
    eq(await partNumber('/r2/mp_part_with_io'), 2, 'upload_part_with (twin)');
    const w = await t.get('/r2/mp_with?key=mp6');
    ok(w.body.startsWith('Ok key=mp6 size=9 ') && w.body.includes(' cc=max-age=30 ') && w.body.includes(' custom=origin=mp '), `got ${w.body}`);
    ok((await t.get('/r2/mp_with_io?key=mp7')).body.includes(' cc=max-age=30 '), 'the twin');
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
