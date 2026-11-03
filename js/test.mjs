// The test helper of an app (research/design-notes/test-helper.md, rules TH1 to TH19): the built app (`app.wasm` and the
// shim `.roc-cfw/`) in Miniflare, with local bindings, a clock, binding call counts and an outbound table.
//   import { startApp } from './.roc-cfw/test.mjs';
//   const app = await startApp({ dir: '.', d1: { DB: ['sql/0001_init.sql'] }, count: ['DB'], now: 1767225600000 });
//   const res = await app.fetch('/path'); res.calls.DB.n; await app.reset(); await app.close();
// `.mjs`: this file runs only in Node, so the module lists of `*.js` (the shim) never take it. The isolate part is
// `test-entry.js`. No npm dependency: the app's test setup installs `wrangler` or `miniflare` (TH10).
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { manifestOf, NOT_STACK_FIRST } from './runner.js';
import { manifestEvent } from './events.js';
import { checkManifest } from './manifest.js';
import { parseToml, parseJsonc, optionsFileOf } from './cli.mjs';

// TH13: equal to `test` of cfw.json. A breaking change of `startApp` adds 1.
export const TEST_API = 1;
const here = dirname(fileURLToPath(import.meta.url));
const REQUEST_HEADER = 'cfw-test-request';
const CALLS_HEADER = 'cfw-test-calls';
const DEFAULT_DATE = '2026-10-01';
const DEFAULT_FLAGS = ['enable_request_signal'];

// TH12, T6: the `request.cf` of each request, with no network (the placeholder of Miniflare, as conformance/run.mjs).
export const DEFAULT_CF = {
  asOrganization: '', asn: 395747, colo: 'DFW', city: 'Austin', region: 'Texas', regionCode: 'TX', postalCode: '78701',
  country: 'US', continent: 'NA', timezone: 'America/Chicago', latitude: '30.27130', longitude: '-97.74260', clientTcpRtt: 0,
  httpProtocol: 'HTTP/1.1', requestPriority: 'weight=192;exclusive=0', tlsCipher: 'AEAD-AES128-GCM-SHA256', tlsVersion: 'TLSv1.3',
};

// ---- Miniflare (TH10) ----

// The places, in order: the option `miniflare` (a dir or the module), env MINIFLARE, `miniflare` and
// `wrangler/node_modules/miniflare` from the project, the global wrangler of this node.
export function findMiniflare({ miniflare, dir = process.cwd(), env = process.env, execPath = process.execPath } = {}) {
  if (miniflare && typeof miniflare === 'object') return miniflare;
  const tried = [];
  const load = (path) => {
    tried.push(path);
    try {
      return createRequire(join(dir, 'package.json'))(path);
    } catch {
      return null;
    }
  };
  if (typeof miniflare === 'string') {
    const m = load(resolve(dir, miniflare));
    if (m) return m;
  }
  if (env.MINIFLARE) {
    const m = load(resolve(env.MINIFLARE));
    if (m) return m;
  }
  for (const name of ['miniflare', 'wrangler/node_modules/miniflare']) {
    tried.push(`${name} (from ${dir})`);
    try {
      const req = createRequire(join(dir, 'package.json'));
      return req(name === 'miniflare' ? name : join(dirname(req.resolve('wrangler/package.json')), 'node_modules/miniflare'));
    } catch {
      // not there
    }
  }
  const m = load(join(dirname(dirname(execPath)), 'lib/node_modules/wrangler/node_modules/miniflare'));
  if (m) return m;
  throw new Error(`startApp: no Miniflare. Looked at:\n  ${tried.join('\n  ')}\nInstall it in the project (npm i -D wrangler), or give the option miniflare, or set MINIFLARE to the dir of the miniflare package.`);
}

// ---- The run dir and the signals (TH9, O7) ----

let serial = 0;
const live = new Set();
let parentDir = null;
let savedTmp;
let baseTmp;
const cleanupAll = () => {
  for (const a of live) rmSync(a.runDir, { recursive: true, force: true });
  if (parentDir) rmSync(parentDir, { recursive: true, force: true });
};
let signalsOn = false;
function signals() {
  if (signalsOn) return;
  signalsOn = true;
  process.on('exit', cleanupAll);
  for (const [sig, code] of [['SIGTERM', 143], ['SIGINT', 130]]) {
    process.once(sig, async () => {
      await Promise.all([...live].map((a) => a.mf.dispose().catch(() => {})));
      cleanupAll();
      process.exit(code);
    });
  }
}

// ---- SQL (TH19): the split rules of the seeds ----

// The statements of an SQL text in order. A `;` ends a statement only outside quotes, comments, BEGIN ... END and CASE ... END
// (a trigger has `;` inside). D1 `exec` splits at each newline, so the helper runs one statement at a time.
export function splitSql(text) {
  const out = [];
  let cur = '';
  let depth = 0;
  let i = 0;
  const n = text.length;
  const flush = () => {
    const sql = cur.trim();
    if (sql) out.push(sql);
    cur = '';
  };
  while (i < n) {
    const c = text[i];
    if (c === "'" || c === '"' || c === '`') {
      const j = text.indexOf(c, i + 1);
      const end = j < 0 ? n : j + 1;
      cur += text.slice(i, end);
      i = end;
    } else if (c === '-' && text[i + 1] === '-') {
      const j = text.indexOf('\n', i);
      i = j < 0 ? n : j;
    } else if (c === '/' && text[i + 1] === '*') {
      const j = text.indexOf('*/', i + 2);
      i = j < 0 ? n : j + 2;
    } else if (c === ';' && depth === 0) {
      flush();
      i++;
    } else if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < n && /[A-Za-z0-9_]/.test(text[j])) j++;
      const word = text.slice(i, j).toUpperCase();
      if (word === 'BEGIN' || word === 'CASE') depth++;
      else if (word === 'END' && depth > 0) depth--;
      cur += text.slice(i, j);
      i = j;
    } else {
      cur += c;
      i++;
    }
  }
  flush();
  return out;
}

// A seed item: a file path (relative to `dir`) when it ends in `.sql` and exists, else SQL text.
const sqlOf = (dir, item) => {
  if (typeof item !== 'string') throw new TypeError(`startApp: a SQL seed must be a text or a .sql path, got ${typeof item}`);
  const p = resolve(dir, item);
  return /\.sql$/i.test(item.trim()) && existsSync(p) ? readFileSync(p, 'utf8') : item;
};

// ---- The outbound table (TH18) ----

const bytesOf = (body) => (body === undefined || body === null ? null : typeof body === 'string' ? new TextEncoder().encode(body) : body instanceof Uint8Array ? body : body instanceof ArrayBuffer ? new Uint8Array(body) : null);

// An answer of the table (or of an outbound function) as a Response. A body gets a Content-Length: Miniflare sends a Node
// answer with no length otherwise (Talon slice 111). A `Response` is read and sent again with its length. `chunked: true`: no length, the body in chunks
// of `chunkBytes` (default 16 KiB), for a byte count or a size limit test (a Content-Length cannot send more bytes than it
// says: workerd frames the body by it). A `ReadableStream` body is sent as it is (no length).
export async function answerOf(a) {
  if (a instanceof Response) {
    const body = a.body === null ? null : new Uint8Array(await a.clone().arrayBuffer());
    return answerOf({ status: a.status, headers: a.headers, body });
  }
  const status = a.status ?? 200;
  const headers = new Headers(a.headers ?? {});
  const b = bytesOf(a.body);
  if (a.body instanceof ReadableStream) return new Response(a.body, { status, headers });
  if (b === null) {
    if (a.body !== undefined && a.body !== null) throw new TypeError('outbound: an answer body must be a text, bytes or a ReadableStream');
    return new Response(null, { status, headers });
  }
  if (a.chunked) {
    headers.delete('content-length');
    const size = a.chunkBytes ?? 16384;
    let at = 0;
    const stream = new ReadableStream({
      pull(c) {
        if (at >= b.length) return c.close();
        c.enqueue(b.slice(at, at + size));
        at += size;
      },
    });
    return new Response(stream, { status, headers });
  }
  if (!headers.has('content-length')) headers.set('content-length', String(b.length));
  return new Response(b, { status, headers });
}

function outboundOf(spec) {
  const state = { log: [], count: {}, unmatched: [], seen: new Map() };
  const fn = async (req) => {
    const key = `${req.method} ${req.url}`;
    state.log.push(key);
    state.count[key] = (state.count[key] ?? 0) + 1;
    if (typeof spec === 'function') return answerOf(await spec(req));
    const list = spec?.[key];
    if (!list) {
      state.unmatched.push(key);
      return answerOf({ status: 599, body: `startApp: no outbound answer for ${key}` });
    }
    const answers = Array.isArray(list) ? list : [list];
    const n = state.seen.get(key) ?? 0;
    state.seen.set(key, n + 1);
    const x = answers[Math.min(n, answers.length - 1)];
    return answerOf(typeof x === 'function' ? await x(req) : x);
  };
  return { fn, state, reset: () => Object.assign(state, { log: [], count: {}, unmatched: [], seen: new Map() }) };
}

// ---- The module list (A1, TH17) ----

// The local JS modules that a module imports (relative paths), again for each. An import that is not relative is a throw (O2).
function localModules(file, root, seen = new Map()) {
  if (seen.has(file)) return seen;
  if (!existsSync(file)) throw new Error(`startApp: ${file} is not there`);
  const text = readFileSync(file, 'utf8');
  seen.set(file, text);
  for (const m of text.matchAll(/(?:^|[\s;])(?:import|export)\s*(?:[^'";]*?\sfrom\s*)?['"]([^'"]+)['"]/g)) {
    const spec = m[1];
    if (spec.startsWith('cloudflare:') || spec.startsWith('node:')) continue;
    if (!spec.startsWith('./') && !spec.startsWith('../')) throw new Error(`startApp: ${relative(root, file)} imports ${spec}, which is not a relative path: give it in the option modules, or bundle the file`);
    const target = resolve(dirname(file), spec);
    if (target !== root && !target.startsWith(root + sep)) throw new Error(`startApp: ${relative(root, file)} imports ${spec}, which is outside of ${root}`);
    localModules(target, root, seen);
  }
  return seen;
}

// The text of the entry module (as `entryOf` of cli.mjs, with the test entry).
export function testEntryText(m, { token, now, count, options, optionsImport, hooksImport }) {
  const objects = Object.keys(m.objects);
  const entrypoints = Object.keys(m.entrypoints);
  const names = ['makeHandler', ...(objects.length ? ['objectClass'] : []), ...(entrypoints.length ? ['entrypointClass'] : [])];
  const lines = [
    '// The entry of startApp (.roc-cfw/test.mjs).',
    "import app from './app.wasm';",
    `import { ${names.join(', ')} } from './.roc-cfw/index.js';`,
    "import { testEntry } from './.roc-cfw/test-entry.js';",
    optionsImport ? `import options from '${optionsImport}';` : 'const options = {};',
    hooksImport ? `import * as hooks from '${hooksImport}';` : 'const hooks = {};',
  ];
  for (const c of objects) lines.push(`export const ${c} = objectClass('${c}');`);
  for (const c of entrypoints) lines.push(`export const ${c} = entrypointClass('${c}');`);
  lines.push(
    `const extra = ${JSON.stringify(options ?? {})};`,
    `const t = testEntry({ token: ${JSON.stringify(token)}, now: ${JSON.stringify(now ?? null)}, count: ${JSON.stringify(count)}, hooks, wrapEnv: options.wrapEnv });`,
    'export default t.wrap(makeHandler(app, { ...options, ...extra, now: t.now, wrapEnv: t.wrapEnv }));',
    '',
  );
  return lines.join('\n');
}

// ---- The config ----

function readConfig(dir, given) {
  const file = given ? resolve(dir, given) : ['wrangler.json', 'wrangler.jsonc', 'wrangler.toml'].map((f) => join(dir, f)).find((f) => existsSync(f));
  if (!file) return { file: null, cfg: {} };
  const text = readFileSync(file, 'utf8');
  return { file, cfg: file.endsWith('.toml') ? parseToml(text, basename(file)) : parseJsonc(text) };
}

// The wasm of the config: the import of the `main` entry, else app.wasm (as `wasmOf` of cli.mjs).
function wasmOfConfig(dir, cfg) {
  const entry = typeof cfg.main === 'string' ? resolve(dir, cfg.main) : null;
  if (entry && existsSync(entry)) {
    const m = /(?:from|import)\s*['"]([^'"]+\.wasm)['"]/.exec(readFileSync(entry, 'utf8'));
    if (m) return resolve(dirname(entry), m[1]);
  }
  return join(dir, 'app.wasm');
}

// TH20: the limit of a rate limit binding when neither `ratelimits` nor the config gives it: the value of `roc-cfw add` (js/bindings.js).
export const RATELIMIT_DEFAULT = { limit: 100, period: 60 };

// The rate limits of the config: `[[ratelimits]]` and `unsafe.bindings` of type ratelimit, as { name: { namespace_id, simple } }.
function configRatelimits(cfg) {
  const list = [...(cfg.ratelimits ?? []), ...(cfg.unsafe?.bindings ?? []).filter((b) => b.type === 'ratelimit')];
  return Object.fromEntries(list.filter((b) => b && typeof b.name === 'string').map((b) => [b.name, b]));
}

// The Miniflare form of one rate limit binding (option `ratelimits`, then the config, then RATELIMIT_DEFAULT).
function ratelimitOf(name, index, opts, fromConfig) {
  const given = opts.ratelimits?.[name];
  const conf = fromConfig[name];
  const simple = given ?? conf?.simple ?? RATELIMIT_DEFAULT;
  const { limit, period = 60 } = simple;
  if (typeof limit !== 'number' || !(limit > 0)) throw new Error(`startApp: the rate limit ${name}: limit must be a number above 0, got ${JSON.stringify(limit)}`);
  if (period !== 10 && period !== 60) throw new Error(`startApp: the rate limit ${name}: period must be 10 or 60 (Miniflare), got ${JSON.stringify(period)}`);
  return { namespace_id: String(conf?.namespace_id ?? index + 1), simple: { limit, period } };
}

const KNOWN = new Set(['dir', 'wasm', 'shim', 'config', 'now', 'd1', 'kv', 'r2', 'queues', 'outbound', 'services', 'bindings', 'compatibility', 'count', 'hooks', 'options', 'miniflare', 'persist', 'modules', 'cf', 'miniflareOptions', 'ratelimits']);

// ---- startApp ----

export async function startApp(opts = {}) {
  for (const k of Object.keys(opts)) if (!KNOWN.has(k)) throw new Error(`startApp: unknown option ${k}. Known: ${[...KNOWN].join(', ')}`);
  const dir = resolve(opts.dir ?? '.');
  const shimDir = resolve(dir, opts.shim ?? '.roc-cfw');
  if (!existsSync(join(shimDir, 'index.js'))) throw new Error(`startApp: ${join(shimDir, 'index.js')} is not there: run roc-cfw sync (or roc-cfw shim) in ${dir}, or give the option shim`);
  for (const f of ['test-entry.js']) if (!existsSync(join(shimDir, f))) throw new Error(`startApp: ${join(shimDir, f)} is not there: the shim is older than the test helper (cfw.json "test" 1)`);
  const { cfg } = readConfig(dir, opts.config);
  const wasmFile = opts.wasm ? resolve(dir, opts.wasm) : wasmOfConfig(dir, cfg);
  if (!existsSync(wasmFile)) throw new Error(`startApp: ${wasmFile} is not there: build the app first`);
  const wasmBytes = readFileSync(wasmFile);

  // TH1: the manifest in Node.
  const got = manifestOf(new WebAssembly.Module(wasmBytes), manifestEvent());
  if (got === undefined) throw new Error(`startApp: ${wasmFile}: ${NOT_STACK_FIRST}`);
  const m = checkManifest(got ?? { objects: {}, entrypoints: {} });
  const declared = new Map(m.bindings.map((b) => [b.name, b]));
  const seedKinds = { d1: 'd1', kv: 'kv', r2: 'r2', queues: 'queue' };
  for (const [opt, kind] of Object.entries(seedKinds)) {
    for (const name of Object.keys(opts[opt] ?? {})) {
      const b = declared.get(name);
      if (!b) throw new Error(`startApp: the option ${opt} names ${name}, and the app does not declare it (Worker.new bindings)`);
      if (b.kind !== kind) throw new Error(`startApp: the option ${opt} names ${name}, which the app declares as ${b.kind}`);
    }
  }
  const count = opts.count ?? [];
  if (!Array.isArray(count) || !count.every((n) => typeof n === 'string')) throw new TypeError('startApp: count must be an array of binding names');

  // TH2: each declared binding with a local form; the others need `services`, `bindings` or `hooks`.
  const services = opts.services ?? {};
  const vars = { ...(cfg.vars ?? {}), ...(opts.bindings ?? {}) };
  const queueOf = (name) => (cfg.queues?.producers ?? []).find((p) => p.binding === name)?.queue ?? name.toLowerCase();
  const mfo = { d1Databases: [], kvNamespaces: [], r2Buckets: [], queueProducers: {}, queueConsumers: {}, durableObjects: {}, serviceBindings: {}, ratelimits: {} };
  const rlConfig = configRatelimits(cfg);
  for (const name of Object.keys(opts.ratelimits ?? {})) {
    const b = declared.get(name);
    if (!b) throw new Error(`startApp: the option ratelimits names ${name}, and the app does not declare it (Worker.new bindings)`);
    if (b.kind !== 'ratelimit') throw new Error(`startApp: the option ratelimits names ${name}, which the app declares as ${b.kind}`);
  }
  for (const b of m.bindings) {
    if (b.kind === 'd1') mfo.d1Databases.push(b.name);
    else if (b.kind === 'kv') mfo.kvNamespaces.push(b.name);
    else if (b.kind === 'r2') mfo.r2Buckets.push(b.name);
    else if (b.kind === 'queue') mfo.queueProducers[b.name] = queueOf(b.name);
    else if (b.kind === 'ratelimit' && !Object.hasOwn(services, b.name)) mfo.ratelimits[b.name] = ratelimitOf(b.name, Object.keys(mfo.ratelimits).length, opts, rlConfig);
    else if (b.kind === 'object' && !b.script) mfo.durableObjects[b.name] = { className: b.class, useSQLite: true };
    else if (Object.hasOwn(services, b.name)) continue;
    else if (Object.hasOwn(vars, b.name) || opts.hooks) continue;
    else throw new Error(`startApp: the binding ${b.name} (${b.kind}) has no local form in Miniflare: give it in services (a Node function) or bindings, or make it in a hooks module`);
  }
  for (const [name, fn] of Object.entries(services)) mfo.serviceBindings[name] = fn;
  // The consumers of this Worker: the queues of the config, else each producer queue when the app has a queue handler.
  const consumers = cfg.queues?.consumers ?? (m.handlers.includes('queue') ? Object.values(mfo.queueProducers).map((queue) => ({ queue })) : []);
  for (const c of consumers) mfo.queueConsumers[c.queue] = { maxBatchSize: c.max_batch_size ?? 10, maxBatchTimeout: c.max_batch_timeout ?? 1, ...(opts.queues?.[Object.keys(mfo.queueProducers).find((k) => mfo.queueProducers[k] === c.queue)] ?? {}) };

  // The modules (A1): the entry, the shim (each *.js of shimDir as .roc-cfw/), the options file and the hooks module with
  // their local imports, app.wasm, the option modules.
  const token = randomBytes(12).toString('hex');
  const mainEntry = resolve(dir, typeof cfg.main === 'string' ? cfg.main : 'worker.js');
  const optionsFile = optionsFileOf(mainEntry);
  const local = new Map();
  if (existsSync(optionsFile)) localModules(optionsFile, dir, local);
  const hooksFile = opts.hooks ? resolve(dir, opts.hooks) : null;
  if (hooksFile) localModules(hooksFile, dir, local);
  const rel = (f) => `./${relative(dir, f).split(sep).join('/')}`;
  const entryPath = join(dir, `__cfw_test_entry_${token}.js`);
  const modules = [
    { type: 'ESModule', path: entryPath, contents: testEntryText(m, { token, now: opts.now ?? null, count, options: opts.options, optionsImport: existsSync(optionsFile) ? rel(optionsFile) : null, hooksImport: hooksFile ? rel(hooksFile) : null }) },
    ...readdirSync(shimDir).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(dir, '.roc-cfw', f), contents: readFileSync(join(shimDir, f), 'utf8') })),
    ...[...local].map(([path, contents]) => ({ type: 'ESModule', path, contents })),
    { type: 'CompiledWasm', path: join(dir, 'app.wasm'), contents: wasmBytes },
    ...(opts.modules ?? []).map((x) => ({ ...x, path: isAbsolute(x.path) ? x.path : resolve(dir, x.path) })),
  ];
  // A path twice (an option module of the same path as a shim file): the later one wins.
  const moduleList = [...new Map(modules.map((x) => [x.path, x])).values()];

  // TH9: the run dir, and TMPDIR for the temp dirs of Miniflare.
  signals();
  // The base is the temp dir before the first startApp changed TMPDIR (O7).
  if (!parentDir) {
    savedTmp = process.env.TMPDIR;
    baseTmp = tmpdir();
    parentDir = join(baseTmp, `cfw-test-${process.pid}`);
    mkdirSync(parentDir, { recursive: true });
    process.env.TMPDIR = parentDir;
  }
  const n = ++serial;
  const runDir = join(baseTmp, `cfw-test-${process.pid}-${n}`);
  mkdirSync(runDir, { recursive: true });

  const { Miniflare, convertV4MiniflareOptions } = findMiniflare({ miniflare: opts.miniflare, dir });
  const out = outboundOf(opts.outbound);
  const logs = [];
  const comp = opts.compatibility ?? {};
  const persist = opts.persist ? { d1Persist: join(runDir, 'd1'), kvPersist: join(runDir, 'kv'), r2Persist: join(runDir, 'r2'), durableObjectsPersist: join(runDir, 'do'), cachePersist: join(runDir, 'cache') } : {};
  const v4 = {
    modules: moduleList,
    modulesRoot: dir,
    compatibilityDate: comp.date ?? cfg.compatibility_date ?? DEFAULT_DATE,
    compatibilityFlags: comp.flags ?? cfg.compatibility_flags ?? DEFAULT_FLAGS,
    port: 0,
    cf: opts.cf ?? DEFAULT_CF,
    unsafeTriggerHandlers: true,
    handleStructuredLogs: (l) => logs.push(l),
    bindings: vars,
    outboundService: (req) => out.fn(req),
    ...Object.fromEntries(Object.entries(mfo).filter(([, v]) => (Array.isArray(v) ? v.length : Object.keys(v).length))),
    ...persist,
    ...(opts.miniflareOptions ?? {}),
  };
  // TH20: `miniflareOptions.ratelimits` adds to the rate limits of the helper (a plain spread would drop them: the other bindings).
  if (opts.miniflareOptions?.ratelimits) v4.ratelimits = { ...mfo.ratelimits, ...opts.miniflareOptions.ratelimits };
  const mf = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(v4) : v4);
  const app = { mf, runDir };
  live.add(app);
  let url;
  try {
    url = await mf.ready;
  } catch (e) {
    live.delete(app);
    await mf.dispose().catch(() => {});
    rmSync(runDir, { recursive: true, force: true });
    const why = String(e.message).split('\n').find((l) => l.includes('Uncaught')) ?? e.message;
    // TH20: workerd gives "internal error" with no detail; name the options that can cause it.
    const hint = /internal error/.test(why) && v4.ratelimits ? ` (rate limits are set: ${Object.keys(v4.ratelimits).join(', ')}; check that each one is { namespace_id: text, simple: { limit, period: 10 or 60 } } and that the Miniflare version is the one of this helper)` : '';
    throw new Error(`startApp: the Worker did not start: ${why}${hint}`);
  }

  // ---- The handles and the seeds ----
  const d1Seeds = Object.fromEntries(Object.entries(opts.d1 ?? {}).map(([k, list]) => [k, (Array.isArray(list) ? list : [list]).map((x) => sqlOf(dir, x))]));
  const runSql = async (name, texts) => {
    const db = await mf.getD1Database(name);
    for (const text of Array.isArray(texts) ? texts : [texts]) for (const s of splitSql(sqlOf(dir, text))) await db.prepare(s).run();
  };
  const seed = async () => {
    for (const [name, texts] of Object.entries(d1Seeds)) await runSql(name, texts);
    for (const [name, entries] of Object.entries(opts.kv ?? {})) {
      const kv = await mf.getKVNamespace(name);
      for (const [k, v] of Object.entries(entries)) await kv.put(k, typeof v === 'string' || v instanceof Uint8Array ? v : JSON.stringify(v));
    }
    for (const [name, entries] of Object.entries(opts.r2 ?? {})) {
      const r2 = await mf.getR2Bucket(name);
      for (const [k, v] of Object.entries(entries)) await r2.put(k, v);
    }
  };
  await seed().catch(async (e) => {
    await close();
    throw e;
  });

  // ---- The control path (TH5, TH8, TH15) ----
  const ctl = async (path, query = {}) => {
    const q = new URLSearchParams(Object.entries(query).map(([k, v]) => [k, String(v)]));
    const res = await mf.dispatchFetch(`http://localhost/__cfw_test/${token}/${path}?${q}`);
    const body = await res.json();
    if (!res.ok) throw new Error(`startApp: ${path}: ${body.error ?? res.status}`);
    return body;
  };
  let clock = opts.now ?? null;
  const setNow = async (ms) => {
    if (ms !== null && !Number.isFinite(ms)) throw new TypeError(`setNow: ms must be a number or null, got ${ms}`);
    clock = ms;
    await ctl('now', { ms: ms === null ? 'null' : ms });
  };
  let reqN = 0;
  let closed = false;

  // TH3, TH4: the defaults of a request.
  const fetchApp = async (pathOrUrl, init = {}) => {
    const { now, ...rest } = init;
    if (now !== undefined) await setNow(now);
    const target = /^[a-z]+:\/\//i.test(pathOrUrl) ? pathOrUrl : `http://localhost${pathOrUrl.startsWith('/') ? '' : '/'}${pathOrUrl}`;
    const headers = new Headers(rest.headers ?? {});
    const id = ++reqN;
    headers.set(REQUEST_HEADER, String(id));
    const body = typeof rest.body === 'string' ? Buffer.from(rest.body) : rest.body;
    const res = await mf.dispatchFetch(target, { ...rest, headers, body, cache: rest.cache ?? 'force-cache', redirect: rest.redirect ?? 'manual' });
    const raw = res.headers.get(CALLS_HEADER);
    const rec = raw ? JSON.parse(decodeURIComponent(raw)) : { calls: [], sessions: {} };
    try {
      res.headers.delete(CALLS_HEADER);
    } catch {
      // immutable headers: the header stays
    }
    res.calls = group(rec.calls);
    res.sessions = rec.sessions;
    res.request = id;
    return res;
  };
  // { binding: { n, ops, list: [{ op, session }] } } (TH6, TH16).
  const group = (calls) => {
    const g = {};
    for (const name of count) g[name] = { n: 0, ops: [], list: [] };
    for (const c of calls) {
      const x = (g[c.binding] ??= { n: 0, ops: [], list: [] });
      x.n++;
      x.ops.push(c.op);
      x.list.push({ op: c.op, session: c.session, kind: c.kind, name: c.name, ...(c.body ? { body: c.body } : {}), ...(c.bodies ? { bodies: c.bodies } : {}), ...(c.contentType ? { contentType: c.contentType } : {}) });
    }
    return g;
  };

  const idle = async (ms = 5000) => {
    const end = Date.now() + ms;
    for (;;) {
      const { tasks } = await ctl('tasks');
      if (tasks === 0) return;
      if (Date.now() > end) throw new Error(`idle: ${tasks} tasks still run after ${ms} ms`);
      await new Promise((r) => setTimeout(r, 10));
    }
  };

  // TH15: D1 (drop the user tables, run the seeds again), KV and R2 (list and delete), the isolate part (the clock, the
  // pins, the cache keys, the calls), the outbound state.
  const clearD1 = async (name) => {
    const db = await mf.getD1Database(name);
    const rows = (await db.prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'd1_%' AND type IN ('table', 'view')").all()).results;
    if (!rows.length) return;
    const q = (s) => `"${s.replace(/"/g, '""')}"`;
    await db.batch([db.prepare('PRAGMA defer_foreign_keys = on'), ...rows.filter((r) => r.type === 'view').map((r) => db.prepare(`DROP VIEW IF EXISTS ${q(r.name)}`)), ...rows.filter((r) => r.type === 'table').map((r) => db.prepare(`DROP TABLE IF EXISTS ${q(r.name)}`))]);
  };
  const clearKv = async (name) => {
    const kv = await mf.getKVNamespace(name);
    let cursor;
    do {
      const page = await kv.list({ cursor });
      await Promise.all(page.keys.map((k) => kv.delete(k.name)));
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
  };
  const clearR2 = async (name) => {
    const r2 = await mf.getR2Bucket(name);
    let cursor;
    do {
      const page = await r2.list({ cursor });
      if (page.objects.length) await r2.delete(page.objects.map((o) => o.key));
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  };
  const reset = async () => {
    await idle();
    await ctl('reset');
    clock = opts.now ?? null;
    for (const name of mfo.d1Databases) await clearD1(name);
    for (const name of mfo.kvNamespaces) await clearKv(name);
    for (const name of mfo.r2Buckets) await clearR2(name);
    out.reset();
    logs.length = 0;
    await seed();
  };

  async function close() {
    if (closed) return;
    closed = true;
    live.delete(app);
    await mf.dispose().catch(() => {});
    rmSync(runDir, { recursive: true, force: true });
    if (live.size === 0 && parentDir) {
      rmSync(parentDir, { recursive: true, force: true });
      parentDir = null;
      if (savedTmp === undefined) delete process.env.TMPDIR;
      else process.env.TMPDIR = savedTmp;
    }
  }

  return Object.assign(app, {
    url,
    logs,
    manifest: m,
    token,
    fetch: fetchApp,
    setNow,
    async advance(ms) {
      await setNow((clock ?? Date.now()) + ms);
    },
    get now() {
      return clock;
    },
    async scheduled({ cron, time, now } = {}) {
      if (now !== undefined) await setNow(now);
      const c = cron ?? m.crons[0] ?? cfg.triggers?.crons?.[0] ?? '* * * * *';
      const q = new URLSearchParams({ cron: c, time: String(time ?? clock ?? Date.now()), format: 'json' });
      const res = await mf.dispatchFetch(`http://localhost/cdn-cgi/local/scheduled?${q}`);
      return res.json();
    },
    async queue(name, messages, { now } = {}) {
      if (now !== undefined) await setNow(now);
      const at = new Date(clock ?? Date.now());
      const list = messages.map((x, i) => ({ id: x.id ?? String(i + 1), timestamp: x.timestamp ?? at, body: x.body, attempts: x.attempts ?? 1 }));
      return (await mf.getWorker()).queue(name, list);
    },
    d1: (name) => mf.getD1Database(name),
    kv: (name) => mf.getKVNamespace(name),
    r2: (name) => mf.getR2Bucket(name),
    queueProducer: (name) => mf.getQueueProducer(name),
    object: (name) => mf.getDurableObjectNamespace(name),
    async calls({ reset: r = false } = {}) {
      return group((await ctl('calls', r ? { reset: 1 } : {})).calls);
    },
    idle,
    sql: runSql,
    outbound: () => ({ log: [...out.state.log], count: { ...out.state.count }, unmatched: [...out.state.unmatched] }),
    reset,
    close,
  });
}
