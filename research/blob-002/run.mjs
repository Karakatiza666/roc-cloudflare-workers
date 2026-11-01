// Repro runner: node run.mjs <app.wasm> [miniflare dir]. Runs GET / on the app in Miniflare with a local D1 `DB`.
import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const mfDir = process.argv[3] ?? process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
// REG=1: the entry and options of the Talon registry harness (worker/tests/run.mjs, worker-test.js: a Proxy of env.DB, d1Persist).
const reg = process.env.REG === '1';
const regDir = join(root, '../worker/tests');
const wjs0 = "import app from './app.wasm';\nimport { makeHandler } from './js/index.js';\nexport default makeHandler(app);\n";
const modules = [
  ...(reg
    ? [{ type: 'ESModule', path: join(here, 'worker.js'), contents: readFileSync(join(regDir, 'worker-test.js'), 'utf8').replaceAll('./.roc-cfw/', './js/') },
       { type: 'ESModule', path: join(here, 'clock.js'), contents: readFileSync(join(regDir, 'clock.js'), 'utf8') }]
    : [{ type: 'ESModule', path: join(here, 'worker.js'), contents: wjs0 }]),
  ...readdirSync(join(root, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: readFileSync(join(root, 'js', f), 'utf8') })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(process.argv[2]) },
];
const mf = new Miniflare(convertV4MiniflareOptions({ modules, modulesRoot: here, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], d1Databases: ['DB'], ...(reg ? { d1Persist: join(process.env.TMPDIR ?? '/tmp', `blob-${process.pid}`), compatibilityFlags: ['enable_request_signal', 'global_fetch_strictly_public'] } : {}) }));
const r = await mf.dispatchFetch(`http://x/${process.env.PROBE_PATH ?? ''}`);
console.log(r.status, await r.text());
await mf.dispose();
