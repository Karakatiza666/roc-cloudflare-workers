// Probes P1 and P2 of research/design-notes/test-helper.md 10 (step S1), in workerd through Miniflare.
//   node research/test-helper/probes/p1-p2.mjs <helper.wasm>
// P1: `new Request(req, { headers })` keeps `request.signal`: the client aborts, the signal of the copy fires.
// P2: the entry can replace `globalThis.caches`, and the app (Cache.roc: `Get(Root("global"), "caches")`) sees the wrap.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../../..');
const run = join(root, '.cache/tmp', `probe-${process.pid}`);
mkdirSync(run, { recursive: true });
process.env.TMPDIR = run;
process.on('exit', () => rmSync(run, { recursive: true, force: true }));
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const cf = { colo: 'DFW', country: 'US' };
const base = { compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0, cf };

// P1: a plain JS worker.
const p1 = `
const seen = {};
export default { async fetch(req) {
  const u = new URL(req.url);
  if (u.pathname === '/seen') return Response.json(seen);
  const id = u.searchParams.get('id');
  const h = new Headers(req.headers); h.delete('x-strip');
  const copy = new Request(req, { headers: h });
  const s = (seen[id] = { sameSignal: copy.signal === req.signal, headerGone: !copy.headers.has('x-strip'), copyAborted: false, origAborted: false });
  copy.signal.addEventListener('abort', () => (s.copyAborted = true));
  req.signal.addEventListener('abort', () => (s.origAborted = true));
  await scheduler.wait(2000);
  return new Response('late');
} };`;
const mf1 = new Miniflare(convertV4MiniflareOptions({ ...base, modules: true, script: p1 }));
const url = await mf1.ready;
// (a) An undici fetch that aborts after 300 ms. (b) A raw socket that resets (TCP RST) after 300 ms, as
// bench/signal-workerd.mjs. Both through the URL of Miniflare (its entry worker sends the request on to the app).
const ac = new AbortController();
const pending = fetch(new URL('/?id=a', url), { headers: { 'x-strip': '1' }, signal: ac.signal }).catch((e) => e.name);
await new Promise((r) => setTimeout(r, 300));
ac.abort();
await pending;
const net = await import('node:net');
const sock = net.connect(Number(url.port), url.hostname, () => sock.write(`GET /?id=b HTTP/1.1\r\nHost: localhost\r\nx-strip: 1\r\n\r\n`));
await new Promise((r) => setTimeout(r, 300));
sock.resetAndDestroy();
await new Promise((r) => setTimeout(r, 800));
const seen = await (await mf1.dispatchFetch('http://localhost/seen')).json();
console.log('P1 abort', JSON.stringify(seen.a), '| reset', JSON.stringify(seen.b));
await mf1.dispose();

// P2: the helper app behind an entry that wraps globalThis.caches.
const wasm = process.argv[2];
const shim = join(root, 'js');
const entry = `
import app from './app.wasm';
import { makeHandler, objectClass } from './js/index.js';
export const Room = objectClass('Room');
const keys = [];
const real = globalThis.caches;
const wrapCache = (c, name) => new Proxy(c, { get(t, k) {
  const v = t[k];
  if (k === 'put') return (req, res) => (keys.push([name, typeof req === 'string' ? req : req.url]), v.call(t, req, res));
  return typeof v === 'function' ? v.bind(t) : v;
} });
const wrapped = { default: wrapCache(real.default, null), open: async (n) => wrapCache(await real.open(n), n) };
let assign = 'ok';
try { globalThis.caches = wrapped; } catch (e) { assign = 'throw ' + e.message; }
if (globalThis.caches !== wrapped) {
  try { Object.defineProperty(globalThis, 'caches', { value: wrapped, configurable: true, writable: true }); assign += '; defineProperty'; } catch (e) { assign += '; define throw ' + e.message; }
}
const H = makeHandler(app);
export default class extends H {
  async fetch(req) {
    const p = new URL(req.url).pathname;
    if (p === '/__keys') return Response.json({ assign, isWrapped: globalThis.caches === wrapped, keys });
    if (p === '/__clear') { for (const [n, k] of keys) await (n === null ? real.default : await real.open(n)).delete(k); keys.length = 0; return new Response('cleared'); }
    return super.fetch(req);
  }
}`;
const modules = [
  { type: 'ESModule', path: join(root, 'entry.js'), contents: entry },
  ...readdirSync(shim).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(root, 'js', f), contents: readFileSync(join(shim, f), 'utf8') })),
  { type: 'CompiledWasm', path: join(root, 'app.wasm'), contents: readFileSync(wasm) },
];
const mf2 = new Miniflare(convertV4MiniflareOptions({ ...base, modules, modulesRoot: root, d1Databases: ['DB'], kvNamespaces: ['KV'], r2Buckets: ['BUCKET'], queueProducers: { JOBS: 'jobs' }, durableObjects: { ROOMS: { className: 'Room', useSQLite: true } } }));
await mf2.ready;
const get = async (p) => (await mf2.dispatchFetch(`http://localhost${p}`)).text();
const u = encodeURIComponent('https://x.test/a');
console.log('P2 put default', await get(`/cache/put?url=${u}&v=one`), '| put named', await get(`/cache/put?url=${u}&name=n1&v=two`));
console.log('P2 get default', await get(`/cache/get?url=${u}`), '| get named', await get(`/cache/get?url=${u}&name=n1`));
console.log('P2 keys', await get('/__keys'));
console.log('P2 clear', await get('/__clear'));
console.log('P2 after clear', await get(`/cache/get?url=${u}`), '|', await get(`/cache/get?url=${u}&name=n1`));
await mf2.dispose();
