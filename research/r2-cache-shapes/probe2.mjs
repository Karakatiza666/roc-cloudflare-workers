// Probe 2: checksums, conditions with two fields, range without a range, list options, the Cache without cache-control.
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
export default { async fetch(req, env) {
  const out = {};
  const b = env.BUCKET;
  const data = new TextEncoder().encode('hello world');
  const good = new Uint8Array(await crypto.subtle.digest('SHA-256', data));
  const bad = new Uint8Array(32);
  try { const o = await b.put('c1', data, { sha256: good }); out.goodBytes = Object.keys(o.checksums.toJSON()); out.sha256prop = o.checksums.sha256 && new Uint8Array(o.checksums.sha256).length; out.md5prop = o.checksums.md5 && new Uint8Array(o.checksums.md5).length; } catch (e) { out.goodBytes = 'ERR ' + e.message; }
  try { await b.put('c2', data, { sha256: bad }); out.badBytes = 'OK'; } catch (e) { out.badBytes = 'ERR ' + e.name + ' ' + e.message; }
  const p = await b.put('c3', data);
  out.noChecksum = Object.keys(p.checksums.toJSON());
  const etag = p.etag;
  const past = new Date(Date.now() - 100000);
  out.twoFields = String(await b.put('c3', 'y', { onlyIf: { etagMatches: etag, uploadedBefore: past } }));
  out.oneField = String(!!(await b.put('c3', 'z', { onlyIf: { etagMatches: etag } })));
  const g = await b.get('c3');
  out.rangeNone = JSON.stringify(g.range) + ' ' + JSON.stringify((await b.head('c3')).range);
  out.fields = { hasChecksums: !!g.checksums };
  const g2 = await b.get('c3', { range: { suffix: 1 } });
  out.suffix = g2.range;
  await b.put('a', '1'); await b.put('b', '2'); await b.put('c', '3');
  const l = await b.list({ startAfter: 'b', prefix: '' });
  out.startAfter = l.objects.map((o) => o.key);
  const l2 = await b.list({ limit: 2 });
  out.limit = { keys: l2.objects.map((o) => o.key), truncated: l2.truncated, cursor: typeof l2.cursor };
  out.listProps = Object.getOwnPropertyNames(l2).concat(Object.getOwnPropertyNames(Object.getPrototypeOf(l2)));
  out.listChecksums = Object.keys(l2.objects[0].checksums.toJSON());
  await caches.default.put('https://example.com/nocc', new Response('x'));
  out.noCC = String(await caches.default.match('https://example.com/nocc'));
  await caches.default.put('https://example.com/cc', new Response('x', { headers: { 'cache-control': 'max-age=60' } }));
  out.cc = await caches.default.delete('https://example.com/cc');
  const named = await caches.open('mine');
  await named.put('https://example.com/n', new Response('n', { headers: { 'cache-control': 'max-age=60' } }));
  out.named = [String((await caches.default.match('https://example.com/n'))), (await (await named.match('https://example.com/n')).text())];
  return Response.json(out);
} }`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', r2Buckets: ['BUCKET'], port: 0 }));
const res = await mf.dispatchFetch('http://localhost/');
console.log(JSON.stringify(await res.json(), null, 1));
await mf.dispose();
