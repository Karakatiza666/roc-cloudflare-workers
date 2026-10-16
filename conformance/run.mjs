// The conformance runner (PLAN.md 8c): conformance/app.roc (built to a wasm) in Miniflare, used as a library, with
// local bindings. Each file `checks/<module>.mjs` gives its Miniflare options (its bindings) and its checks. The runner
// prints one line for each check, `PASS <name>: <detail>` or `FAIL <name>: <why>`, and exits 1 on a failure.
//   node conformance/run.mjs [app.wasm] [name-filter]      (default: bench/out/conformance.wasm)
// Env: MINIFLARE, the directory of the miniflare package (default: the one that the global wrangler of this node has).
import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const wasm = process.argv[2] ?? join(root, 'bench/out/conformance.wasm');
const filter = process.argv[3];
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

// The `request.cf` of each request: the placeholder of Miniflare (`fallbackCf` in its source, what it gives when it cannot
// fetch the cf of this machine), with no `metroCode`, as the cf of a place outside the US. No network, the same each run.
const cf = {
  asOrganization: '', asn: 395747, colo: 'DFW', city: 'Austin', region: 'Texas', regionCode: 'TX', postalCode: '78701',
  country: 'US', continent: 'NA', timezone: 'America/Chicago', latitude: '30.27130', longitude: '-97.74260', clientTcpRtt: 0,
  httpProtocol: 'HTTP/1.1', requestPriority: 'weight=192;exclusive=0', tlsCipher: 'AEAD-AES128-GCM-SHA256', tlsVersion: 'TLSv1.3',
};

// A local HTTP server for the `Http` checks: `/hello` (text), `/ten` (10 bytes), `/slow` (answers after 2 s), `/echo` (the
// method, the header `x-test` and the body), `/status/<n>` (that status, no body).
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const path = new URL(req.url, 'http://x').pathname;
    if (path === '/hello') return res.end('hello');
    if (path === '/ten') return res.end('0123456789');
    if (path === '/slow') return setTimeout(() => res.end('late'), 2000);
    if (path === '/echo') return res.end(`${req.method} ${req.headers['x-test'] ?? '-'} ${Buffer.concat(chunks).toString()}`);
    if (path.startsWith('/status/')) {
      res.statusCode = Number(path.slice(8));
      return res.end();
    }
    res.statusCode = 404;
    res.end('no route');
  });
});
server.listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const serverUrl = `http://127.0.0.1:${server.address().port}`;

// The check files, in name order. Options: arrays are joined, objects are merged (a later file cannot replace a name).
const checkFiles = readdirSync(join(here, 'checks')).filter((f) => f.endsWith('.mjs')).sort();
const suites = [];
for (const f of checkFiles) suites.push({ file: f, ...(await import(pathToFileURL(join(here, 'checks', f)))) });
const merged = {};
for (const s of suites) {
  for (const [k, v] of Object.entries(s.options ?? {})) {
    if (Array.isArray(v)) merged[k] = [...(merged[k] ?? []), ...v];
    else if (v && typeof v === 'object') {
      for (const name of Object.keys(v)) if (merged[k] && name in merged[k]) throw new Error(`${s.file}: the option ${k}.${name} is in two check files`);
      merged[k] = { ...(merged[k] ?? {}), ...v };
    } else throw new Error(`${s.file}: the option ${k} must be an array or an object`);
  }
}

// The modules of the worker, by their names: worker.js, the shim (js/*.js, from the root of the repo) and app.wasm.
const modules = [
  { type: 'ESModule', path: join(here, 'worker.js'), contents: readFileSync(join(here, 'worker.js'), 'utf8') },
  ...readdirSync(join(root, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: readFileSync(join(root, 'js', f), 'utf8') })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(wasm) },
];
const logs = [];
// A worker that does not start (a throw at load, for example a bad shim option) is the failure `start`.
const mf = new Miniflare(convertV4MiniflareOptions({
  modules,
  modulesRoot: here,
  compatibilityDate: '2026-10-01',
  compatibilityFlags: ['enable_request_signal'],
  port: 0,
  cf,
  // `/cdn-cgi/local/scheduled` and `/cdn-cgi/local/email` (the checks of the cron and the email handlers, 8f).
  unsafeTriggerHandlers: true,
  handleStructuredLogs: (l) => logs.push(l),
  ...merged,
}));
try {
  await mf.ready;
} catch (e) {
  console.log(`FAIL start: ${String(e.message).split('\n').find((l) => l.includes('Uncaught')) ?? e.message}`.slice(0, 400));
  server.close();
  process.exit(1);
}

// What a check gets: `get(path)` gives { status, body, waits, awaits, calls, ms } (`awaits`, `calls`: the crossings), `logs` (the structured log lines of workerd since
// the start), `server` (the URL of the local server), `mf` (the Miniflare instance).
const t = {
  server: serverUrl,
  mf,
  logs,
  // For a check that needs more workers (a Tail Worker, 8f): a new Miniflare with these V4 options, with the same `compatibilityDate`,
  // `cf` and flags, and the modules of the worker of the app (`modules`, with `app.wasm`).
  modules,
  startMiniflare: (o) => new Miniflare(convertV4MiniflareOptions({ modulesRoot: here, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0, cf, ...o })),
  async get(path, init) {
    const res = await mf.dispatchFetch(`http://localhost${path}`, init);
    const n = (h) => Number(res.headers.get(h));
    return { status: res.status, body: await res.text(), waits: n('x-waits'), awaits: n('x-awaits'), calls: n('x-calls'), ms: n('x-ms') };
  },
};

let failed = 0, passed = 0;
for (const s of suites) {
  for (const [name, check] of s.checks ?? []) {
    if (filter && !name.includes(filter)) continue;
    try {
      const detail = await check(t);
      passed++;
      console.log(`PASS ${name}${detail ? `: ${detail}` : ''}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e.message}`);
    }
  }
}

// The end: no task, no ref, no context, no alarm, no live byte of a task (RS1, PLAN.md 10c).
const st = JSON.parse(await (await mf.dispatchFetch('http://localhost/__stats')).text());
const endOk = st.tasks === 0 && st.refsLive === 0 && st.contextsLive === 0 && st.alarms === 0 && st.live === 0;
console.log(`${endOk ? 'PASS' : 'FAIL'} end: ${JSON.stringify(st)}`);
if (!endOk) failed++;
await mf.dispose();
server.close();
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
