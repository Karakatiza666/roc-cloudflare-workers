// Assets with a method and headers (PLAN.md 8f part 4): what the local Assets binding of Miniflare gives for a POST, a HEAD, If-None-Match and Range.
//   node research/bindings-probe/assets.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const here = new URL('.', import.meta.url).pathname;
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `export default { async fetch(request, env) {
  const out = [];
  for (const [m, h, p] of [['POST', {}, '/hello.txt'], ['HEAD', {}, '/hello.txt'], ['GET', {'if-none-match': '"2d96d414ac136e92b55d6b1853ffaba3"'}, '/hello.txt'], ['GET', {range: 'bytes=0-4'}, '/hello.txt']]) {
    try { const r = await env.ASSETS.fetch('http://x' + p, { method: m, headers: h, body: m === 'POST' ? 'abc' : undefined }); out.push([m, r.status, (await r.text()).length, r.headers.get('content-length')]); } catch (e) { out.push([m, 'err', e.message]); }
  }
  return new Response(JSON.stringify(out)); } };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: [{ type: 'ESModule', path: join(here, 'w.mjs'), contents: script }], compatibilityDate: '2026-10-01', port: 0, assets: { directory: join(here, 'assets'), binding: 'ASSETS', run_worker_first: true, routerConfig: { has_user_worker: true } } }));
await mf.ready; console.log(await (await mf.dispatchFetch('http://localhost/')).text()); await mf.dispose();
