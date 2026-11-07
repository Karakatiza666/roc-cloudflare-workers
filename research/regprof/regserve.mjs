// Copy of talon/worker/tests/serve.mjs (read only, 2026-11-07) for the CPU profile of the registry Worker
// (research/regprof/README.md). Changes: imports by path into talon/worker; Miniflare gets `inspectorPort`
// (env INSPECT_PORT, default 9230), so regprof.mjs can use the V8 profiler of workerd. V8 flags of workerd:
// env MINIFLARE_WORKERD_V8_FLAGS (Miniflare), e.g. "--no-wasm-inlining".
// The Worker as an HTTP server for one L3 case (slice 224, the contract run, step l3w of scripts/test.sh).
// It starts the built Worker (app.wasm of the step wbuild) with startApp of the platform (.roc-cfw/test.mjs), the config and hooks of W2
// (wrangler-test.toml, hooks.js), a local D1 with the migrations of sql/, the seed of the case, and the fake GitHub of W2 (fakegithub.mjs).
// startApp gives a listening URL (Miniflare `ready`), but its port is random. This script serves a node:http proxy on 127.0.0.1:<port> that sends each
// request to `app.fetch`, so the port is fixed (the registry origin is part of the cache path of tln, R-IX1) and each request is in a log.
//   node worker/tests/serve.mjs <worker dir of the case> <state dir> <port>
//   <worker dir of the case>  `<case>/worker/` of tests/scenarios (it can be missing: no seed, no GitHub route):
//     seed.sql          optional. Statements that run after the migrations (the form of W2 seed.sql)
//     github/           optional. The fake GitHub of W2 (the form of the doc comment of run.mjs, names encoded as TESTING.md 3.1, not decoded)
//     settings.json     optional. More Worker settings, as W2 settings.json
//     ratelimits.json   optional. As W2 ratelimits.json
//   <state dir>  the work dir of the case. The script writes:
//     worker.url          `http://127.0.0.1:<port>` when the server is ready
//     worker.log          one line for each request: `METHOD <path and query> <status>`
//     worker-github.log   one line for each request of the Worker to the fake GitHub: `METHOD <url>` (W2 github.log)
//     worker.errs         one line for each fault: a GitHub request with no route or a wrong header, a fault of the proxy, a failed start
// Env: W2_DIR (the build dir: app.wasm and .roc-cfw/), MINIFLARE (as run.mjs), TALON_NOW (the clock of the Worker, RFC 3339; default 2026-01-01T00:00:00Z).
// The script stops on TERM or INT (it closes the app first).
import { createServer } from 'node:http';
import { appendFileSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { splitSql, migrationFiles } from '/home/george/dev/Karakatiza666/talon/sql/tests/split.mjs';
import { fillSettings } from '/home/george/dev/Karakatiza666/talon/worker/tests/oidc.mjs';
import { appSettings, dropNulls } from '/home/george/dev/Karakatiza666/talon/worker/tests/githubapp.mjs';
import { fakeGithub } from '/home/george/dev/Karakatiza666/talon/worker/tests/fakegithub.mjs';

const here = '/home/george/dev/Karakatiza666/talon/worker/tests';
const root = join(here, '..', '..');
const [caseDir, stateDir, portText] = process.argv.slice(2);
const read = (p) => (existsSync(p) ? readFileSync(p, 'utf8') : '');
const errs = [];
const fault = (text) => { errs.push(text); appendFileSync(join(stateDir, 'worker.errs'), `${text}\n`); };
if (!caseDir || !stateDir || !portText) { console.error('usage: serve.mjs <worker dir of the case> <state dir> <port>'); process.exit(2); }

const w2Dir = process.env.W2_DIR ?? join(root, 'worker');
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const DEFAULT_NOW = 1767225600000;
const now = process.env.TALON_NOW ? Date.parse(process.env.TALON_NOW) : DEFAULT_NOW;
if (!Number.isFinite(now)) { fault(`serve: TALON_NOW is not an RFC 3339 time: ${process.env.TALON_NOW}`); process.exit(1); }

// The settings and the rate limits of W2 (run.mjs configOf): the App settings, worker/tests/settings.json, then the settings.json of the case.
const settings = dropNulls({ ...appSettings(), ...JSON.parse(read(join(here, 'settings.json')) || '{}'), ...fillSettings(JSON.parse(read(join(caseDir, 'settings.json')) || '{}')) });
const limits = { RL_INGEST: { limit: 60, period: 60 }, RL_HINTS: { limit: 1000, period: 60 }, RL_LOGIN: { limit: 1000, period: 60 }, ...JSON.parse(read(join(caseDir, 'ratelimits.json')) || '{}') };
const ratelimits = Object.fromEntries(Object.entries(limits).map(([n, r]) => [n, { limit: r.limit, period: r.period ?? 60 }]));

const shimDir = join(w2Dir, '.roc-cfw');
let app;
try {
  const { startApp } = await import(pathToFileURL(join(shimDir, 'test.mjs')).href);
  const ref = { fn: async (req) => new Response(`no fake GitHub yet: ${req.url}`, { status: 599 }) };
  app = await startApp({
    dir: here,
    shim: shimDir,
    wasm: join(w2Dir, 'app.wasm'),
    config: join(here, 'wrangler-test.toml'),
    hooks: 'hooks.js',
    now,
    bindings: settings,
    ratelimits,
    outbound: (req) => ref.fn(req),
    miniflare: mfDir,
    miniflareOptions: { inspectorPort: Number(process.env.INSPECT_PORT ?? 9230) },
  });
  const db = await app.d1('DB');
  const migrations = migrationFiles(join(root, 'sql')).flatMap((f) => splitSql(readFileSync(f, 'utf8')).map((s) => s.sql));
  await db.batch(migrations.map((s) => db.prepare(s)));
  for (const s of splitSql(read(join(caseDir, 'seed.sql')))) await db.prepare(s.sql).run();
  // The fake GitHub writes its errors to `errs`; the log is written to a file after each request.
  const ghLog = [];
  const st = { settings, nowMs: now, tokenLog: [], authLog: [], issued: 0 };
  const gh = fakeGithub(caseDir, ghLog, errs, { db }, st);
  ref.fn = async (req) => {
    const n = errs.length;
    const res = await gh(req);
    writeFileSync(join(stateDir, 'worker-github.log'), ghLog.map((l) => `${l}\n`).join(''));
    for (const e of errs.slice(n)) appendFileSync(join(stateDir, 'worker.errs'), `${e}\n`);
    return res;
  };
} catch (e) {
  fault(`serve: the Worker did not start: ${String(e.message ?? e).split('\n')[0]}`);
  if (app) await app.close().catch(() => {});
  process.exit(1);
}

const stop = async (code) => { server.close(); await app.close().catch(() => {}); process.exit(code); };
const server = createServer(async (req, res) => {
  // POST /__regserve/stop: close the app, then exit. Miniflare stops workerd on its own on TERM, so close() after TERM can be too late
  // (the trace of CFW_TEST_TRACE, research/alloc/scripts/regtrace.sh).
  if (req.method === 'POST' && req.url === '/__regserve/stop') { res.end('stop'); stop(0); return; }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const headers = Object.fromEntries(Object.entries(req.headers).filter(([k]) => !['host', 'connection', 'content-length', 'transfer-encoding'].includes(k)));
  try {
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const r = await app.fetch(req.url, { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body });
    const out = Buffer.from(await r.arrayBuffer());
    const h = {};
    r.headers.forEach((v, k) => { if (!['content-length', 'transfer-encoding', 'content-encoding', 'connection'].includes(k)) h[k] = v; });
    res.writeHead(r.status, h);
    res.end(out);
    appendFileSync(join(stateDir, 'worker.log'), `${req.method} ${req.url} ${r.status}\n`);
  } catch (e) {
    fault(`serve: ${req.method} ${req.url}: ${String(e.message ?? e).split('\n')[0]}`);
    res.writeHead(599);
    res.end('serve fault');
    appendFileSync(join(stateDir, 'worker.log'), `${req.method} ${req.url} 599\n`);
  }
});
server.on('error', (e) => { fault(`serve: no server on 127.0.0.1:${portText}: ${e.message}`); stop(1); });
server.listen(Number(portText), '127.0.0.1', () => {
  const tmp = join(stateDir, 'worker.url.part');
  writeFileSync(tmp, `http://127.0.0.1:${server.address().port}`);
  renameSync(tmp, join(stateDir, 'worker.url'));
});
process.once('SIGTERM', () => stop(143));
process.once('SIGINT', () => stop(130));
