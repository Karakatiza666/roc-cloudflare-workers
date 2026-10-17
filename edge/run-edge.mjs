// PLAN.md 11c: the checks of conformance/checks/*.mjs against the deployed edge app (edge/deploy.sh), not Miniflare.
//   EDGE=https://rocplat-test-app.<sub>.workers.dev SERVER=https://rocplat-test-echo.<sub>.workers.dev node edge/run-edge.mjs [filter]
// What differs from conformance/run.mjs:
//   `t.get` and `t.mf.dispatchFetch` are a `fetch` of the edge URL. `t.server` is the echo Worker (edge/echo.js).
//   `t.mf.getD1Database`, `getKVNamespace`, `getR2Bucket` reach the real bindings through `POST /__js` of edge/worker.js.
//   `t.logs` are the lines of `wrangler tail` (they come seconds late, so a log check can fail by time).
//   `t.start`, `t.startMiniflare`, `t.mf.getWorker`, `unsafeEvictDurableObject` and the other Miniflare-only calls throw
//   "MF-ONLY": the check cannot run on the edge.
// One line for each check: `PASS <name>: <detail>` or `FAIL <name>: <why>`. No `end` check (no `/__stats` sums across isolates).
import { spawn } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const EDGE = process.env.EDGE.replace(/\/$/, '');
const SERVER = process.env.SERVER.replace(/\/$/, '');
const filter = process.argv[2];
const skip = (process.env.SKIP ?? '').split(',').filter(Boolean);

const mfOnly = (what) => () => { throw new Error(`MF-ONLY: ${what}`); };
const b64 = (u) => Buffer.from(u.buffer ?? u, u.byteOffset ?? 0, u.byteLength).toString('base64');
const enc = (a) => (a && a.__chain ? { $chain: a.__chain } : a instanceof Uint8Array || a instanceof ArrayBuffer ? { $bytes: b64(a instanceof ArrayBuffer ? new Uint8Array(a) : a) } : a);
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
        return (res, rej) => fetch(`${EDGE}/__js`, { method: 'POST', body: JSON.stringify({ b, chain: chain.map(([m, a]) => [m, a.map(enc)]) }) })
          .then((r) => r.json()).then((j) => (j.err ? Promise.reject(Object.assign(new Error(j.err.message), { name: j.err.name })) : dec(j.ok))).then(res, rej);
      }
      return (...args) => remote(b, [...chain, [prop, args]]);
    },
  });
}

// `wrangler tail` of the app: the log lines as `{ level, message }` (the form of `handleStructuredLogs` of Miniflare).
const logs = [];
const tailProc = spawn('wrangler', ['tail', new URL(EDGE).hostname.split('.')[0], '--format', 'json'], { stdio: ['ignore', 'pipe', 'ignore'] });
let buf = '';
tailProc.stdout.on('data', (d) => {
  buf += d;
  for (;;) {
    const end = buf.indexOf('\n}\n');
    if (end < 0) break;
    try {
      const o = JSON.parse(buf.slice(0, end + 2));
      for (const l of o.logs ?? []) logs.push({ level: l.level === 'log' ? 'info' : l.level, message: l.message.map((m) => (typeof m === 'string' ? m : JSON.stringify(m))).join(' ') });
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
  mfDir: '/nonexistent',
  logs,
  modules: [],
  entry: '',
  mf: {
    dispatchFetch: (url, init) => fetch(EDGE + new URL(url).pathname + new URL(url).search, init),
    getD1Database: async (n) => remote(n),
    getKVNamespace: async (n) => remote(n),
    getR2Bucket: async (n) => remote(n),
    getWorker: mfOnly('getWorker (the queue handler of Miniflare)'),
    unsafeEvictDurableObject: mfOnly('unsafeEvictDurableObject'),
    getSecretsStoreSecretAPI: mfOnly('getSecretsStoreSecretAPI'),
  },
  start: mfOnly('t.start (a second Miniflare)'),
  startMiniflare: mfOnly('t.startMiniflare (a second Miniflare)'),
  async get(path, init) {
    const res = await fetch(EDGE + path, init);
    const n = (h) => Number(res.headers.get(h));
    return { status: res.status, body: await res.text(), waits: n('x-waits'), awaits: n('x-awaits'), calls: n('x-calls'), ms: n('x-ms') };
  },
};

let passed = 0, failed = 0;
for (const f of readdirSync(join(here, '../conformance/checks')).filter((x) => x.endsWith('.mjs')).sort()) {
  if (skip.includes(f.replace('.mjs', ''))) continue;
  const s = await import(pathToFileURL(join(here, '../conformance/checks', f)));
  for (const [name, check] of s.checks ?? []) {
    if (filter && !name.includes(filter)) continue;
    try {
      const detail = await Promise.race([check(t), new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT 90 s')), 90_000))]);
      passed++;
      console.log(`PASS ${name}${detail ? `: ${detail}` : ''}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${String(e.message).slice(0, 600)}`);
    }
  }
}
console.log(`${passed} passed, ${failed} failed`);
tailProc.kill();
process.exit(0);
