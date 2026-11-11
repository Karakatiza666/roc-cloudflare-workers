// PLAN.md 11c: the checks of conformance/checks/*.mjs against the deployed edge app (edge/deploy.sh), not Miniflare.
//   EDGE=https://rocplat-test-app.<sub>.workers.dev SERVER=https://rocplat-test-echo.<sub>.workers.dev node edge/run-edge.mjs [filter]
// Env: CONF, the conformance directory of the checks and of worker.js (default ../conformance; another checkout for
// the run of another tag, edge/deploy.sh SRC).
// What differs from conformance/run.mjs:
//   `t.get` and `t.mf.dispatchFetch` are a `fetch` of the edge URL. `t.server` is the echo Worker (edge/echo.js).
//   `t.mf.getD1Database`, `getKVNamespace`, `getR2Bucket` reach the real bindings through `POST /__js` of edge/worker.js.
//   `t.logs` are the lines of `wrangler tail` (they come seconds late, so a log check can fail by time).
//   `t.start`, `t.startBare`, `t.startMiniflare`, `t.mf.getWorker`, `unsafeEvictDurableObject`, the `/cdn-cgi/local/` routes
//   and the other Miniflare-only calls throw "MF-ONLY": the check cannot run on the edge, and its line is SKIP.
//   `t.entry` is the text of conformance/worker.js (a check that changes it then calls `t.start`: SKIP).
//   `t.wsEcho` is the WebSocket echo server of the echo Worker (`/ws`), in place of the local one of checks/websocket.mjs.
//   EDGE_ONLY_SKIP (below): the checks that need a thing that the edge run does not have, each with its reason. They do not run.
// One line for each check: `PASS <name>: <detail>`, `FAIL <name>: <why>` or `SKIP <name>: <why>`. No `end` check (no
// `/__stats` sums across isolates). The last line: `<p> passed, <f> failed, <s> skipped`.
import { spawn } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const conf = process.env.CONF ?? join(here, '../conformance');
const EDGE = process.env.EDGE.replace(/\/$/, '');
const SERVER = process.env.SERVER.replace(/\/$/, '');
const filter = process.argv[2];
const skip = (process.env.SKIP ?? '').split(',').filter(Boolean);

const mfOnly = (what) => () => { throw new Error(`MF-ONLY: ${what}`); };
// The miniflare package of the global wrangler (as conformance/run.mjs): the checks use its `ws` package as a Node client.
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
// The checks that cannot run on the edge for a reason that is not a Miniflare-only call: [name pattern, reason].
const EDGE_ONLY_SKIP = [
  [/^tail /, 'MF-ONLY: a Tail Worker in a second Miniflare (t.startMiniflare in the setup check)'],
  [/^email (forward|header|set_reject|reply|an Err|raw)/, 'MF-ONLY: the email handler runs from /cdn-cgi/local/email of Miniflare'],
  [/^email send/, 'EDGE: send_email needs Email Routing on a zone of the account (the edge run has none)'],
  [/^hyperdrive /, 'EDGE: a Hyperdrive config needs a Postgres database that the edge can reach (the edge run has none)'],
  [/^tcp /, 'EDGE: the TCP and STARTTLS servers of the check are local (127.0.0.1)'],
  [/^objects a KV-backed class/, 'EDGE: the account cannot make a KV-backed Durable Object namespace (wrangler deploy: code 10099), so the edge app has no KVONLY'],
  [/^secretsstore /, 'MF-ONLY: the secret is made with getSecretsStoreSecretAPI of Miniflare'],
];
const edgeSkip = (name) => EDGE_ONLY_SKIP.find(([re]) => re.test(name))?.[1];
const b64 = (u) => Buffer.from(u.buffer ?? u, u.byteOffset ?? 0, u.byteLength).toString('base64');
// An arg of a call of `/__js`: a chain, bytes (base64, or the request body when larger than 4 MiB: `raw`), a Date, or
// an object or array of these.
const enc = (a, raw) => {
  if (a && a.__chain) return { $chain: a.__chain };
  if (a instanceof Uint8Array || a instanceof ArrayBuffer) {
    const u = a instanceof ArrayBuffer ? new Uint8Array(a) : a;
    if (u.byteLength > 4 * 1024 * 1024 && raw && !raw.body) return ((raw.body = u), { $raw: true });
    return { $bytes: b64(u) };
  }
  if (a instanceof Date) return { $date: a.toISOString() };
  if (Array.isArray(a)) return a.map((x) => enc(x, raw));
  if (a && typeof a === 'object') return Object.fromEntries(Object.entries(a).map(([k, v]) => [k, enc(v, raw)]));
  return a;
};
// The isolates that answered the requests of the check that runs now (the header `x-edge-isolate` of edge/worker.js).
let isolates = new Set();
const seenIsolate = (res) => {
  const id = res.headers.get('x-edge-isolate');
  if (id) isolates.add(id);
  return res;
};
const dec = (v) => {
  if (v && v.$undefined) return undefined;
  if (v && v.$bytes !== undefined) return new Uint8Array(Buffer.from(v.$bytes, 'base64')).buffer;
  if (v && v.$body !== undefined) {
    const bytes = new Uint8Array(Buffer.from(v.$body, 'base64'));
    return { ...v, arrayBuffer: async () => bytes.buffer, text: async () => Buffer.from(bytes).toString(), json: async () => JSON.parse(Buffer.from(bytes).toString()) };
  }
  return v;
};
// A binding as a chain of calls, sent at the first `await`.
function remote(b, chain = []) {
  return new Proxy(function () {}, {
    get(_, prop) {
      if (prop === '__chain') return chain;
      if (prop === 'then') {
        if (chain.length === 0) return undefined;
        const raw = {};
        const call = { b, chain: chain.map(([m, a]) => [m, a.map((x) => enc(x, raw))]) };
        const init = raw.body ? { method: 'POST', headers: { 'x-js': JSON.stringify(call) }, body: raw.body } : { method: 'POST', body: JSON.stringify(call) };
        return (res, rej) => fetch(`${EDGE}/__js`, init)
          .then(seenIsolate).then((r) => r.json()).then((j) => (j.err ? Promise.reject(Object.assign(new Error(j.err.message), { name: j.err.name })) : dec(j.ok))).then(res, rej);
      }
      return (...args) => remote(b, [...chain, [prop, args]]);
    },
  });
}

// `wrangler tail` of the app: the log lines as `{ level, message }` (the form of `handleStructuredLogs` of Miniflare).
// The tail can be seconds late, so a second path is faster: while a check reads `t.logs`, the runner reads `/__logs` of
// edge/worker.js (the lines that each isolate wrote to D1, one read in flight at a time, at most each 100 ms). A line that
// came by one path is not added again when the other path gives it (`early`: the count of each text that came first by
// `/__logs`, `late`: by the tail; either path can be first).
const logs = [];
const early = new Map();
const late = new Map();
// A line of one path: added, unless the other path gave the same text first (then that count goes down by one).
const take = (l, mine, other) => {
  const k = keyOf(l);
  const n = other.get(k) ?? 0;
  if (n > 0) return void other.set(k, n - 1);
  logs.push({ level: l.level, message: l.message });
  mine.set(k, (mine.get(k) ?? 0) + 1);
};
const keyOf = (l) => `${l.level} ${l.message}`;
let since = 0, polling = null, lastPoll = 0;
const poll = () => {
  if (polling || Date.now() - lastPoll < 100) return;
  lastPoll = Date.now();
  polling = (async () => {
    try {
      const rows = await (await fetch(`${EDGE}/__logs?since=${since}`)).json();
      for (const l of rows) {
        if (l.id <= since) continue;
        since = l.id;
        take(l, early, late);
      }
    } catch {}
    polling = null;
  })();
};
const fromTail = (l) => take(l, late, early);
const tailProc = spawn('wrangler', ['tail', new URL(EDGE).hostname.split('.')[0], '--format', 'json'], { stdio: ['ignore', 'pipe', 'ignore'] });
let buf = '';
tailProc.stdout.on('data', (d) => {
  buf += d;
  for (;;) {
    const end = buf.indexOf('\n}\n');
    if (end < 0) break;
    try {
      const o = JSON.parse(buf.slice(0, end + 2));
      for (const l of o.logs ?? []) fromTail({ level: l.level === 'log' ? 'info' : l.level, message: l.message.map((m) => (typeof m === 'string' ? m : JSON.stringify(m))).join(' ') });
    } catch {}
    buf = buf.slice(end + 3);
  }
});
await new Promise((r) => setTimeout(r, 6000)); // the tail needs a few seconds to connect

const t = {
  // A check that has a local form and an edge form of an answer reads this (PLAN.md 11c, EP7). `undefined` in conformance/run.mjs.
  edge: true,
  server: SERVER,
  url: EDGE,
  wsEcho: `${SERVER.replace(/^http/, 'ws')}/ws`,
  mfDir,
  get logs() {
    poll();
    return logs;
  },
  modules: [],
  entry: readFileSync(join(conf, 'worker.js'), 'utf8'),
  mf: {
    dispatchFetch: (url, init) => {
      const u = new URL(url);
      if (u.pathname.startsWith('/cdn-cgi/local/')) throw new Error(`MF-ONLY: ${u.pathname} (a trigger route of Miniflare)`);
      return fetch(EDGE + u.pathname + u.search, init).then(seenIsolate);
    },
    getD1Database: async (n) => remote(n),
    getKVNamespace: async (n) => remote(n),
    getR2Bucket: async (n) => remote(n),
    getWorker: mfOnly('getWorker (the queue handler of Miniflare)'),
    unsafeEvictDurableObject: mfOnly('unsafeEvictDurableObject'),
    getSecretsStoreSecretAPI: mfOnly('getSecretsStoreSecretAPI'),
  },
  start: mfOnly('t.start (a second Miniflare)'),
  startBare: mfOnly('t.startBare (a second Miniflare)'),
  startMiniflare: mfOnly('t.startMiniflare (a second Miniflare)'),
  async get(path, init) {
    const res = seenIsolate(await fetch(EDGE + path, init));
    const n = (h) => Number(res.headers.get(h));
    return { status: res.status, body: await res.text(), waits: n('x-waits'), awaits: n('x-awaits'), calls: n('x-calls'), ms: n('x-ms') };
  },
};

let passed = 0, failed = 0, skipped = 0;
for (const f of readdirSync(join(conf, 'checks')).filter((x) => x.endsWith('.mjs')).sort()) {
  if (skip.includes(f.replace('.mjs', ''))) continue;
  const s = await import(pathToFileURL(join(conf, 'checks', f)));
  for (const [name, check] of s.checks ?? []) {
    if (filter && !name.includes(filter)) continue;
    const why = edgeSkip(name);
    if (why) {
      skipped++;
      console.log(`SKIP ${name}: ${why}`);
      continue;
    }
    // A check whose requests went to two isolates (the per-isolate state of Memo, pins, `/__mem`) and that fails runs
    // again, at most 8 times. The line names the attempts. A FAIL after 8 attempts is a FAIL.
    let line;
    for (let attempt = 1; attempt <= 8; attempt++) {
      isolates = new Set();
      try {
        const detail = await Promise.race([check(t), new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT 90 s')), 90_000))]);
        line = ['PASS', `${detail ? `: ${detail}` : ''}${attempt > 1 ? ` (attempt ${attempt}: isolate hop before)` : ''}`];
        break;
      } catch (e) {
        const msg = String(e.message);
        if (msg.startsWith('MF-ONLY')) {
          line = ['SKIP', `: ${msg.slice(0, 300)}`];
          break;
        }
        line = ['FAIL', `: ${msg.slice(0, 600)}${isolates.size > 1 ? ` (isolates ${[...isolates].join(',')}, attempt ${attempt})` : ''}`];
        if (isolates.size <= 1) break;
      }
    }
    if (line[0] === 'PASS') passed++;
    else if (line[0] === 'SKIP') skipped++;
    else failed++;
    console.log(`${line[0]} ${name}${line[1]}`);
  }
}
console.log(`${passed} passed, ${failed} failed, ${skipped} skipped`);
tailProc.kill();
process.exit(0);
