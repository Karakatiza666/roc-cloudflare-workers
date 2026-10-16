// Probe: the shapes that Miniflare (local workerd) gives for R2 and Cache objects, to design the programs of
// platform/R2.roc and platform/Cache.roc. node research/r2-cache-shapes/probe.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
const show = (v) => { const o = {}; for (const k in v) o[k] = typeof v[k]; return o; };
export default { async fetch(req, env) {
  const out = {};
  const b = env.BUCKET;
  const put = await b.put('k', 'hello world', { httpMetadata: { cacheControl: 'max-age=60', contentType: 'text/plain' }, customMetadata: { a: '1', b: '2' } });
  out.putProto = Object.getPrototypeOf(put).constructor.name;
  out.putKeys = Object.getOwnPropertyNames(put).concat(Object.getOwnPropertyNames(Object.getPrototypeOf(put)));
  out.put = { key: put.key, version: put.version, size: put.size, etag: put.etag, httpEtag: put.httpEtag, uploaded: typeof put.uploaded + ':' + (put.uploaded instanceof Date), httpMetadata: put.httpMetadata, customMetadata: put.customMetadata, storageClass: put.storageClass };
  const cs = put.checksums;
  out.checksumsType = cs.constructor.name; out.checksumsJson = cs.toJSON(); out.md5type = Object.prototype.toString.call(cs.md5);
  out.httpMetaProto = Object.getPrototypeOf(put.httpMetadata) === Object.prototype;
  out.customProto = Object.getPrototypeOf(put.customMetadata) === Object.prototype;
  out.missing = String(await b.get('nope')) + ' ' + String(await b.head('nope'));
  const g = await b.get('k', { range: { offset: 2, length: 3 } });
  out.range = g.range; out.size = g.size; out.text = await g.text();
  const g2 = await b.get('k', { onlyIf: { etagMatches: 'wrong' } });
  out.onlyIfGet = { body: String(g2.body), cls: g2.constructor.name, hasBody: 'body' in g2 };
  out.onlyIfPut = String(await b.put('k', 'x', { onlyIf: { etagMatches: 'wrong' } }));
  out.absentPut = String(await b.put('k', 'x', { onlyIf: { etagDoesNotMatch: '*' } }));
  out.fresh = String(!!(await b.put('fresh', 'x', { onlyIf: { etagDoesNotMatch: '*' } })));
  const l = await b.list({ include: ['httpMetadata'] });
  out.list = { truncated: l.truncated, cursor: l.cursor, delimitedPrefixes: l.delimitedPrefixes, httpMeta0: l.objects[0].httpMetadata, custom0: l.objects[0].customMetadata };
  const l2 = await b.list();
  out.list2 = { http0: l2.objects[0].httpMetadata, custom0: l2.objects[0].customMetadata };
  const un = new FixedLengthStream(3);
  const ws = new TransformStream();
  try { await b.put('ts', ws.readable); } catch (e) { out.unknownLength = e.name + ': ' + e.message; }
  try { await b.put('bad', 'x', { sha256: 'abcd' }); } catch (e) { out.badSha = e.name + ': ' + e.message; }
  const mp = await b.createMultipartUpload('mp');
  out.mp = { key: mp.key, uploadId: typeof mp.uploadId, proto: mp.constructor.name };
  const cache = caches.default;
  out.cacheMissing = String(await cache.match('https://example.com/x'));
  out.cacheDelete = await cache.delete('https://example.com/x');
  try { await cache.put('https://example.com/p', new Response('x', { status: 206 })); } catch (e) { out.cache206 = e.name + ': ' + e.message; }
  await cache.put('https://example.com/ok', new Response('cached', { headers: { 'cache-control': 'max-age=60', 'content-type': 'text/plain' } }));
  const hit = await cache.match('https://example.com/ok');
  out.hit = { status: hit.status, headers: [...hit.headers], text: await hit.text() };
  return Response.json(out);
} }`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', r2Buckets: ['BUCKET'], port: 0 }));
const res = await mf.dispatchFetch('http://localhost/');
console.log(JSON.stringify(await res.json(), null, 1));
await mf.dispose();
