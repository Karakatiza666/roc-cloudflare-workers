// PLAN.md 11c: the worker of the edge app (edge/app.roc) on Cloudflare. It is the worker of the conformance app
// (conformance/worker.js, copied by edge/deploy.sh as `conformance-worker.js`) with these changes, so the two do not
// drift apart:
//   - The queues of the edge have the prefix `rocplat-test-`. `queue` removes it before the conformance worker and the
//     Roc app see the name (`jobs`, `v8`, `decv`, ...).
//   - The JS consumers (`v8`, `decj`, `decvjs`, `b64j`) can run in another isolate than the request that reads what
//     they got. So they write it to D1 (table `edge_seen`), and `/__queue_seen` and `/__dec_seen` read it from there.
//   - The state of the JS stubs of conformance/bindings.js (the calls, the Vectorize store) is per isolate, and the
//     edge sends the requests of one check to many isolates. So a request that can use the stubs loads the state from D1
//     (table `edge_stub_state`) first and saves it at its end: the state is the same in each isolate.
//   - Each console call (the line as `wrangler tail` gives it) also goes to D1 (table `edge_logs`), from each isolate
//     of the Worker and of its Durable Objects: `GET /__logs?since=<id>` gives the lines after that row. edge/run-edge.mjs
//     reads them while a check waits for a line, because `wrangler tail` can be seconds late. A line over 64 kB goes
//     only to the tail.
//   - The routes of the edge run: `/__edge`, `/__js`, `/__jsgrow`, `/__blob` (below).
import Base from './conformance-worker.js';
import { readFlag } from './js/host.js';
import { stubState, setStubState } from './bindings.js';
import { env as cfEnv } from 'cloudflare:workers';
export * from './conformance-worker.js';

const PREFIX = 'rocplat-test-';
const JS_QUEUES = new Set(['v8', 'decj', 'decvjs', 'b64j']);
// 11c: JS memory that `/__jsgrow` holds (the 128 MB check with the JS heap).
const held = [];
// 11c: an id of this isolate (made at the first request: no random value at global scope), its start and its request count.
let isolate = null;

// The id of this isolate (the header `x-edge-isolate`), made at the first request (no random value at global scope).
let logIso = null;
// The log lines that are not yet in D1. A write starts at the next turn (a timer) and at the end of each request
// (`waitUntil`). A failed write loses the lines of the fast path only (the tail has them).
const unsent = [];
let flushTimer = null;
const logsTable = 'CREATE TABLE IF NOT EXISTS edge_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT, message TEXT)';
function flushLogs() {
  flushTimer = null;
  if (!unsent.length || !cfEnv?.DB) return Promise.resolve();
  const db = cfEnv.DB;
  const lines = unsent.splice(0);
  return db.batch([db.prepare(logsTable), ...lines.map((l) => db.prepare('INSERT INTO edge_logs (level, message) VALUES (?, ?)').bind(l.level, l.message))]).catch(() => {});
}
const logText = (m) => {
  if (typeof m === 'string') return m;
  try {
    return JSON.stringify(m);
  } catch {
    return String(m);
  }
};
for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
  const orig = console[level].bind(console);
  console[level] = (...args) => {
    const message = args.map(logText).join(' ');
    if (message.length <= 65536) {
      unsent.push({ level: level === 'log' ? 'info' : level, message });
      flushTimer ??= setTimeout(flushLogs, 0);
    }
    orig(...args);
  };
}

// The paths that can use the stubs (`STUB_*`, the bucket `TRACE`), and the state of the stubs in D1 (one row).
const STUB_PATHS = /^\/(__stub_calls|__stub_reset|__d1_calls|ai\/|vectorize\/|analytics\/|workflows\/|r2\/|d1\/batch)/;
const stubTable = (db) => db.prepare('CREATE TABLE IF NOT EXISTS edge_stub_state (k INTEGER PRIMARY KEY, state TEXT)').run();
async function loadStubs(db) {
  await stubTable(db);
  const row = await db.prepare('SELECT state FROM edge_stub_state WHERE k = 1').first();
  if (row) setStubState(row.state);
  return row?.state ?? stubState();
}
async function saveStubs(db, loaded) {
  const now = stubState();
  if (now !== loaded) await db.prepare('INSERT OR REPLACE INTO edge_stub_state (k, state) VALUES (1, ?)').bind(now).run();
}

const seenTable = (db) => db.prepare('CREATE TABLE IF NOT EXISTS edge_seen (n INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, rec TEXT)').run();

export default class extends Base {
  async queue(batch) {
    const name = batch.queue.startsWith(PREFIX) ? batch.queue.slice(PREFIX.length) : batch.queue;
    if (JS_QUEUES.has(name)) {
      // The same records as conformance/worker.js (`seen` of `v8`, `decSeen` of the others).
      const db = this.env.DB;
      await seenTable(db);
      for (const m of batch.messages) {
        const b = m.body;
        const rec = name === 'v8'
          ? { kind: 'queue', v: { id: m.id, n: b.n, big: `${typeof b.big} ${String(b.big)}`, isUint8Array: b.data instanceof Uint8Array, data: b.data instanceof Uint8Array ? [...b.data] : b.data } }
          : { kind: 'dec', v: { queue: name, text: JSON.stringify(b, (_k, v) => (typeof v === 'bigint' ? `${v}n` : v)) } };
        await db.prepare('INSERT INTO edge_seen (kind, rec) VALUES (?, ?)').bind(rec.kind, JSON.stringify(rec.v)).run();
        m.ack();
      }
      return flushLogs();
    }
    // The batch with the name of the local run. Methods are called on the real batch.
    const local = new Proxy(batch, { get: (t, k) => (k === 'queue' ? name : typeof t[k] === 'function' ? t[k].bind(t) : t[k]) });
    try {
      return await super.queue(local);
    } finally {
      await flushLogs();
    }
  }

  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/__queue_seen' || path === '/__dec_seen') {
      const db = this.env.DB;
      await seenTable(db);
      const { results } = await db.prepare('SELECT rec FROM edge_seen WHERE kind = ? ORDER BY n').bind(path === '/__queue_seen' ? 'queue' : 'dec').all();
      return Response.json(results.map((r) => JSON.parse(r.rec)));
    }
    if (path === '/__logs') {
      const db = this.env.DB;
      await db.prepare(logsTable).run();
      const { results } = await db.prepare('SELECT id, level, message FROM edge_logs WHERE id > ? ORDER BY id LIMIT 2000').bind(Number(new URL(request.url).searchParams.get('since') ?? 0)).all();
      return Response.json(results);
    }
    logIso ??= crypto.randomUUID().slice(0, 8);
    const r = Base.runner;
    // 11c, 5d: the isolate, the request count, the two flags of 5a, and the counters of the runner and the task table.
    isolate ??= { id: crypto.randomUUID().slice(0, 8), since: Date.now(), requests: 0 };
    isolate.requests++;
    if (path === '/__edge') {
      const x = r.x;
      return Response.json({
        isolate, signal: x?.__instance_signal ? readFlag(x, '__instance_signal') : null,
        terminated: x?.__instance_terminated ? readFlag(x, '__instance_terminated') : null,
        memBytes: x?.memory.buffer.byteLength, live: x?.live_bytes(), tasks: r.tasks.size,
        stats: { served: r.stats.served, traps: r.stats.traps, cpu: r.stats.cpu, terminated: r.stats.terminated, oom: r.stats.oom, replaces: r.stats.replaces, cancelled: r.stats.cancelled, alarms: r.stats.alarms },
        cancels: r.tasks.stats.byReason, budget: r.stats.budget,
      });
    }
    // 11c: the bindings for the setup and the reads of the checks (`t.mf.getD1Database`, `getKVNamespace`, `getR2Bucket` of
    // edge/run-edge.mjs). Body: `{ b, chain }`, a chain of `[method, args]` on `env[b]`. An arg `{ $chain }` is a chain on the
    // same binding (a D1 statement of a batch), `{ $bytes }` is base64. A result with a body is read to `{ $body }`.
    if (path === '/__js' && request.method === 'POST') {
      // A large bytes arg comes as the request body (`{ $raw: true }`), with the call in the header `x-js`.
      const raw = request.headers.get('x-js');
      const { b, chain } = raw ? JSON.parse(raw) : await request.json();
      const run = async (c) => {
        let v = this.env[b];
        for (const [m, args] of c) v = await v[m](...await Promise.all(args.map(arg)));
        return v;
      };
      // `{ $date }` is a Date (R2 `httpMetadata.cacheExpiry`). Objects and arrays are read field by field.
      const arg = async (a) => {
        if (a === null || typeof a !== 'object') return a;
        if (a.$chain) return run(a.$chain);
        if (a.$bytes !== undefined) return Uint8Array.from(atob(a.$bytes), (c) => c.charCodeAt(0));
        if (a.$date !== undefined) return new Date(a.$date);
        if (a.$raw) return request.body;
        if (Array.isArray(a)) return Promise.all(a.map(arg));
        const o = {};
        for (const [k, v] of Object.entries(a)) o[k] = await arg(v);
        return o;
      };
      const b64 = (buf) => { let s = ''; const u = new Uint8Array(buf); for (let i = 0; i < u.length; i += 32768) s += String.fromCharCode(...u.subarray(i, i + 32768)); return btoa(s); };
      const out = async (v) => {
        if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return { $bytes: b64(v.buffer ?? v) };
        if (v && typeof v.arrayBuffer === 'function') {
          const plain = {};
          for (const k of ['key', 'size', 'etag', 'httpEtag', 'uploaded', 'httpMetadata', 'customMetadata', 'range', 'checksums', 'version', 'storageClass']) if (k in v) plain[k] = v[k];
          return { ...JSON.parse(JSON.stringify(plain)), $body: b64(await v.arrayBuffer()) };
        }
        return v === undefined ? { $undefined: true } : v;
      };
      try {
        return Response.json({ ok: await out(await run(chain)) });
      } catch (e) {
        return Response.json({ err: { name: e.name, message: e.message } });
      }
    }
    // 11c: `mb` MiB of JS memory (ArrayBuffers, each byte written), held for `hold` ms, then dropped.
    if (path === '/__jsgrow') {
      const q = new URL(request.url).searchParams;
      const mine = [];
      for (let i = 0; i < Number(q.get('mb')); i++) { const b = new Uint8Array(1 << 20); b.fill(i & 255); mine.push(b); }
      held.push(mine);
      await new Promise((res) => setTimeout(res, Number(q.get('hold') ?? 0)));
      held.splice(held.indexOf(mine), 1);
      return new Response(`jsgrew mb=${mine.length} isolate=${isolate.id}`);
    }
    // 11c (coordinator item): the JS kind of a D1 BLOB in `all()`, `raw()` and `first()`, for a literal and for a bound Uint8Array.
    if (path === '/__blob') {
      const db = this.env.DB;
      const kindOf = (b) => `${Object.prototype.toString.call(b)}${b && b.length !== undefined ? ` len=${b.length}` : ''}${b && b.byteLength !== undefined ? ` bytes=${b.byteLength}` : ''} ${JSON.stringify(b instanceof ArrayBuffer ? [...new Uint8Array(b)] : ArrayBuffer.isView(b) ? [...b] : b)}`;
      const out = {};
      try {
        const lit = db.prepare("SELECT x'00ff10' AS b");
        out.literal = { all: kindOf((await lit.all()).results[0].b), raw: kindOf((await lit.raw())[0][0]), first: kindOf(await lit.first('b')), firstRow: kindOf((await lit.first()).b) };
        await db.prepare('CREATE TABLE IF NOT EXISTS blob_edge (k TEXT PRIMARY KEY, b BLOB)').run();
        await db.prepare('INSERT OR REPLACE INTO blob_edge (k, b) VALUES (?, ?)').bind('u8', new Uint8Array([0, 255, 16])).run();
        const back = db.prepare("SELECT b, typeof(b) AS t FROM blob_edge WHERE k = 'u8'");
        const row = await back.first();
        out.bound = { sqliteType: row.t, all: kindOf((await back.all()).results[0].b), raw: kindOf((await back.raw())[0][0]), first: kindOf(row.b) };
      } catch (e) {
        out.error = `${e.name}: ${e.message}`;
      }
      return Response.json(out);
    }
    let res;
    if (STUB_PATHS.test(path)) {
      const loaded = await loadStubs(this.env.DB);
      res = await super.fetch(request);
      await saveStubs(this.env.DB, loaded);
    } else res = await super.fetch(request);
    // The isolate of each answer: edge/run-edge.mjs runs a check again when its requests went to two isolates.
    if (res.status === 101 || res.webSocket) return res;
    this.ctx?.waitUntil?.(flushLogs());
    const out = new Response(res.body, res);
    out.headers.set('x-edge-isolate', logIso);
    return out;
  }
}
