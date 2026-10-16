// Does local workerd check the `locationHint` of `getByName` and `get` (PLAN.md 8f, part 1)?
//   node research/objects-probe/hint.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
import { DurableObject } from 'cloudflare:workers';
export class O extends DurableObject { async fetch() { return new Response('ok'); } }
export default { async fetch(req, env) {
  const out = {};
  for (const hint of ['weur', 'apac-ne', 'apacne', 'bogus']) {
    try { out[hint] = await (await env.O.getByName('x', { locationHint: hint }).fetch('http://o/')).text(); } catch (e) { out[hint] = e.name + ': ' + e.message; }
  }
  try { out.idBogus = await (await env.O.get(env.O.idFromName('y'), { locationHint: 'bogus' }).fetch('http://o/')).text(); } catch (e) { out.idBogus = e.name + ': ' + e.message; }
  return Response.json(out);
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', durableObjects: { O: { className: 'O', useSQLite: true } } }));
console.log(await (await mf.dispatchFetch('http://x/')).text());
await mf.dispose();
