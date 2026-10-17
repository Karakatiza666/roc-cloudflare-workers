// PLAN.md 8f part 3: a WebSocket of a Worker (`/websocket/echo` of the conformance app: `accept!`, `respond!`, a loop of
// `receive!`) stays open more than 30 s after its 101 response, with the default deadlines of the shim (`afterRespondMs`
// 30 s) in local workerd. A plain request at 31 s starts the sweep of the task table (PLAN.md 3b).
//   node research/sockets-probe/long.mjs [conformance.wasm]   (about 40 s)
import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const here = join(root, 'conformance');
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const wasm = process.argv[2] ?? join(root, 'bench/out/conformance.wasm');
const modules = [
  { type: 'ESModule', path: join(here, 'worker.js'), contents: readFileSync(join(here, 'worker.js'), 'utf8') },
  ...readdirSync(here).filter((f) => f.endsWith('.js') && f !== 'worker.js').map((f) => ({ type: 'ESModule', path: join(here, f), contents: readFileSync(join(here, f), 'utf8') })),
  ...readdirSync(join(root, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: readFileSync(join(root, 'js', f), 'utf8') })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(wasm) },
];
const logs = [];
const mf = new Miniflare(convertV4MiniflareOptions({ modules, modulesRoot: here, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0, handleStructuredLogs: (l) => logs.push(l) }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
try {
  const base = (await mf.ready).href.replace(/\/$/, '');
  const ws = new WebSocket(base.replace(/^http/, 'ws') + '/websocket/echo');
  const got = [];
  ws.onmessage = (e) => got.push(e.data);
  await new Promise((r) => (ws.onopen = r));
  const t0 = Date.now();
  ws.send('first');
  await sleep(31_000);
  console.log('sweep request:', (await mf.dispatchFetch(`${base}/time/now`)).status);
  await sleep(4_000);
  ws.send('after 35 s');
  await sleep(500);
  console.log(`after ${Math.round((Date.now() - t0) / 1000)} s:`, JSON.stringify(got));
  ws.close(1000, 'done');
  await sleep(300);
  console.log('cancel lines:', logs.filter((l) => String(l.message).includes('cancelled')).length);
} finally {
  await mf.dispose();
}
