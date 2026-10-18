// The conformance runner (PLAN.md 8c): conformance/app.roc (built to a wasm) in Miniflare, used as a library, with
// local bindings. Each file `checks/<module>.mjs` gives its Miniflare options (its bindings) and its checks. The runner
// prints one line for each check, `PASS <name>: <detail>` or `FAIL <name>: <why>`, and exits 1 on a failure.
//   node conformance/run.mjs [app.wasm] [name-filter]      (default: bench/out/conformance.wasm)
// Env: MINIFLARE, the directory of the miniflare package (default: the one that the global wrangler of this node has).
// Temp files: the run has its own TMPDIR, `.cache/tmp/run-<pid>`, so the temp dirs of Miniflare (`miniflare-*`) do not
// go to /tmp. The run removes it at its end, also after a FAIL, a throw, SIGTERM or SIGINT. `reverts.mjs` removes the
// dirs of runs that are not alive (a run killed with SIGKILL).
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const runDir = join(root, '.cache/tmp', `run-${process.pid}`);
mkdirSync(runDir, { recursive: true });
process.env.TMPDIR = runDir;
// Each Miniflare of the run (the app, and the ones that checks start), so a signal can dispose them all.
const live = new Set();
const track = (m) => {
  live.add(m);
  const dispose = m.dispose.bind(m);
  m.dispose = () => {
    live.delete(m);
    return dispose();
  };
  return m;
};
const disposeAll = () => Promise.all([...live].map((m) => m.dispose().catch(() => {})));
process.on('exit', () => rmSync(runDir, { recursive: true, force: true }));
for (const [sig, code] of [['SIGTERM', 143], ['SIGINT', 130]]) {
  process.once(sig, async () => {
    console.log(`FAIL ${sig}: the run stops`);
    await disposeAll();
    process.exit(code);
  });
}
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

// A local HTTP server for the `Http` checks: `/hello` (text), `/ten` (10 bytes), `/slow` (answers after 2 s), `/broken` (6 MiB, then a broken connection), `/echo` (the
// method, the header `x-test` and the body), `/status/<n>` (that status, no body).
const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const path = new URL(req.url, 'http://x').pathname;
    if (path === '/hello') return res.end('hello');
    if (path === '/ten') return res.end('0123456789');
    if (path === '/slow') return setTimeout(() => res.end('late'), 2000);
    // 6 MiB in chunks (no content-length), then the connection breaks: a stream that errors in the middle.
    if (path === '/broken') {
      res.write(Buffer.alloc(6 * 1024 * 1024, 66));
      return setTimeout(() => res.destroy(), 100);
    }
    if (path === '/echo_json') return res.end(`${req.method} ${req.headers['content-type'] ?? '-'} ${Buffer.concat(chunks).toString()}`);
    if (path === '/echo') return res.end(`${req.method} ${req.headers['x-test'] ?? '-'} ${Buffer.concat(chunks).toString()}`);
    // Cloudflare error pages for `Http.cloudflare_error`: the status and the body `error code: <n>` (`/cf64`: 64 bytes, `/cflong`: 76).
    if (path === '/cf530') return ((res.statusCode = 530), res.end('error code: 1016'));
    if (path === '/cf403') return ((res.statusCode = 403), res.end('error code: 1003'));
    if (path === '/cf200') return res.end('error code: 1003');
    if (path === '/cf64') return ((res.statusCode = 403), res.end(`error code: 1003${' '.repeat(48)}`));
    if (path === '/cflong') return ((res.statusCode = 403), res.end(`error code: 1003${' '.repeat(60)}`));
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
    else if (typeof v === 'string') {
      if (merged[k] !== undefined && merged[k] !== v) throw new Error(`${s.file}: the option ${k} is in two check files`);
      merged[k] = v;
    } else if (v && typeof v === 'object') {
      for (const name of Object.keys(v)) if (merged[k] && name in merged[k]) throw new Error(`${s.file}: the option ${k}.${name} is in two check files`);
      merged[k] = { ...(merged[k] ?? {}), ...v };
    } else throw new Error(`${s.file}: the option ${k} must be an array, an object or a text`);
  }
}

// The modules of the worker, by their names: worker.js, the shim (js/*.js, from the root of the repo) and app.wasm.
const modules = [
  { type: 'ESModule', path: join(here, 'worker.js'), contents: readFileSync(join(here, 'worker.js'), 'utf8') },
  // The other JS modules of the worker (conformance/bindings.js: the stubs and the workflow classes).
  ...readdirSync(here).filter((f) => f.endsWith('.js') && f !== 'worker.js').map((f) => ({ type: 'ESModule', path: join(here, f), contents: readFileSync(join(here, f), 'utf8') })),
  ...readdirSync(join(root, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: readFileSync(join(root, 'js', f), 'utf8') })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(wasm) },
];
const logs = [];
// A worker that does not start (a throw at load, for example a bad shim option) is the failure `start`.
const mf = track(new Miniflare(convertV4MiniflareOptions({
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
})));
// The rest runs in `try`: each path to the end (a FAIL at the start, a throw) disposes Miniflare in `finally`.
let failed = 0, passed = 0, started = false, url = null;
try {
  try {
    url = await mf.ready;
    started = true;
  } catch (e) {
    console.log(`FAIL start: ${String(e.message).split('\n').find((l) => l.includes('Uncaught')) ?? e.message}`.slice(0, 400));
    failed = 1;
  }
  if (started) await runChecks();
} finally {
  await disposeAll();
  server.close();
}
if (started) console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

async function runChecks() {
  // What a check gets: `get(path)` gives { status, body, waits, awaits, calls, ms } (`awaits`, `calls`: the crossings), `logs` (the structured log lines of workerd since
  // the start), `server` (the URL of the local server), `mf` (the Miniflare instance).
  const t = {
    server: serverUrl,
    // The URL of the app worker (a WebSocket client of Node connects to it, PLAN.md 8f part 3), and the miniflare package
    // (its `ws` package: the WebSocket echo server of checks/websocket.mjs).
    url: url.href.replace(/\/$/, ''),
    mfDir,
    mf,
    logs,
    // For a check that needs more workers (a Tail Worker, 8f): a new Miniflare with these V4 options, with the same `compatibilityDate`,
    // `cf` and flags, and the modules of the worker of the app (`modules`, with `app.wasm`).
    modules,
    startMiniflare: (o) => track(new Miniflare(convertV4MiniflareOptions({ modulesRoot: here, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0, cf, ...o }))),
    async get(path, init) {
      const res = await mf.dispatchFetch(`http://localhost${path}`, init);
      const n = (h) => Number(res.headers.get(h));
      return { status: res.status, body: await res.text(), waits: n('x-waits'), awaits: n('x-awaits'), calls: n('x-calls'), ms: n('x-ms') };
    },
    // PLAN.md 8f: another Miniflare with the same modules and `opts` (no options of the check files): `entry`, when given,
    // is the text of worker.js (`t.entry` is the real one). The check awaits `ready` and calls `dispose`.
    entry: readFileSync(join(here, 'worker.js'), 'utf8'),
    // The app declares bindings (`Worker.new bindings`, conformance/app.roc) that the shim checks: `start` adds them
    // (DB, KV, COUNTERS) to the options. `startBare` does not (the checks of the load, checks/bindings.mjs).
    start(opts = {}, entry = undefined) {
      return t.startBare({ ...opts, d1Databases: [...new Set(['DB', ...(opts.d1Databases ?? [])])], kvNamespaces: [...new Set(['KV', ...(opts.kvNamespaces ?? [])])], durableObjects: { COUNTERS: { className: 'Counter', useSQLite: true }, ...opts.durableObjects } }, entry);
    },
    startBare(opts = {}, entry = undefined) {
      const mods = entry === undefined ? modules : [{ ...modules[0], contents: entry }, ...modules.slice(1)];
      return track(new Miniflare(convertV4MiniflareOptions({ modules: mods, modulesRoot: here, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0, cf, ...opts })));
    },
  };

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
}
