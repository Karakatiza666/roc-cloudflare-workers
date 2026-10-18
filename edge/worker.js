// PLAN.md 11c: the worker of the edge app (edge/app.roc) on Cloudflare. It is conformance/worker.js with the route
// `GET /__edge` (below). The worker of the conformance app (PLAN.md 8c) in Miniflare: `app.wasm` (conformance/app.roc on the bench platform)
// behind `makeHandler`. Each response has the waits of its task (`x-waits`, the bench export `task_waits`) and its time
// in ms (`x-ms`), and its crossings (`x-awaits`, `x-calls`: the calls of `js_await` and `js_call`, from `stats.crossings`
// of the runner): `run.mjs` sends one request at a time. `GET /__stats`: the task table. `GET /__mem`: the size of wasm memory in bytes (10a).
import app from 'app.wasm';
import { makeHandler, objectClass, entrypointClass } from './js/index.js';
import { readFlag } from './js/host.js';
// 11c, the 128 MB check: the var ISOLATE_BYTES (a deploy of edge/deploy.sh with EXTRA_TOML) raises the budget of M3, so wasm
// can grow past the 128 MB of the isolate. Not set: the default of js/budget.js.
import { env as cfEnv } from 'cloudflare:workers';
import { withStubs, stubRoute, Flow, Waiter } from './bindings.js';
export { Flow, Waiter };

// PLAN.md 8f: the Durable Object classes and the named entry point of the app (conformance/ObjectRoutes.roc,
// RpcRoutes.roc), one line each, before `makeHandler` (the manifest checks them at load).
export const Counter = objectClass('Counter');
export const Store = objectClass('Store');
export const Flaky = objectClass('Flaky');
export const Slow = objectClass('Slow');
export const Ticker = objectClass('Ticker');
export const KvOnly = objectClass('KvOnly');
export const Admin = entrypointClass('Admin');
// PLAN.md 8f part 3: the class of the hibernation API (conformance/WebSocketRoutes.roc).
export const Room = objectClass('Room');
const exported = { Counter, Store, Flaky, Slow, Ticker, KvOnly, Admin, Room };
const kind = (v) => (v === null ? 'null' : Array.isArray(v) ? 'Array' : typeof v === 'object' ? Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto' : typeof v);

// The root `ops` (API.md 6.4). `lib` is an object of functions, not a function (the option check, PLAN.md 8a O4).
const ops = {
  lib: { twice: (n) => n * 2 },
};
// `tailMaxBytes`: 100 kB, so a trace with the logs of 2 MiB (cut by workerd to 200 kB) is above the limit (checks/tail.mjs).
// `initMs`: the `Init` deadline of API.md 10.2, smaller for the test (class `Slow`).
const isolateBytes = cfEnv?.ISOLATE_BYTES ? { isolateBytes: Number(cfEnv.ISOLATE_BYTES) } : {};
const Handler = makeHandler(app, { ops, heapCheckWhenIdle: false, tailMaxBytes: 100_000, initMs: 1000, ...isolateBytes });
// 11c: JS memory that `/__jsgrow` holds (the 128 MB check with the JS heap).
const held = [];

// The messages that the JS consumer of the queue `v8` got (PLAN.md 8f): a `Queue.v8` message with a `Cbor.Bytes` field is
// a `Uint8Array` here, and a `U64` of 2^60 is a `BigInt`. `GET /__queue_seen` gives them.
const seen = [];
// 11c: an id of this isolate (made at the first request: no random value at global scope), its start and its request count.
let isolate = null;

export default class extends Handler {
  async queue(batch) {
    if (batch.queue !== 'rocplat-test-v8') return super.queue(batch);
    for (const m of batch.messages) {
      const b = m.body;
      seen.push({ id: m.id, n: b.n, big: `${typeof b.big} ${String(b.big)}`, isUint8Array: b.data instanceof Uint8Array, data: b.data instanceof Uint8Array ? [...b.data] : b.data });
      console.log('v8 seen', JSON.stringify(seen[seen.length - 1])); // 11c: the consumer can run in another isolate
      m.ack();
    }
  }

  // The JS stubs of conformance/bindings.js are in the env of each request.
  constructor(ctx, env) {
    super(ctx, withStubs(env));
  }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/__queue_seen') return Response.json(seen);
    const r = Handler.runner;
    const stub = stubRoute(path);
    if (stub) return stub;
    if (path === '/__stats') {
      const s = r.tasks.stats;
      return Response.json({ live: r.x.live_bytes(), tasks: r.tasks.size, refsLive: s.refsLive, contextsLive: s.contextsLive, alarms: r.stats.alarms });
    }
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
      const { b, chain } = await request.json();
      const run = async (c) => {
        let v = this.env[b];
        for (const [m, args] of c) v = await v[m](...await Promise.all(args.map(arg)));
        return v;
      };
      const arg = (a) => (a && a.$chain ? run(a.$chain) : a && a.$bytes !== undefined ? Uint8Array.from(atob(a.$bytes), (c) => c.charCodeAt(0)) : a);
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
      await new Promise((r) => setTimeout(r, Number(q.get('hold') ?? 0)));
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
    if (path === '/__mem') return new Response(String(r.x.memory.buffer.byteLength));
    // FO6 (PLAN.md 8f): a JS call with no argument of the RPC method `hello` (argument type `{}`): the default export
    // (`SELF`) and an object of `Counter`.
    if (path === '/__noarg') {
      const out = {};
      for (const [k, stub] of [['default', () => this.env.SELF], ['object', () => this.env.COUNTERS.getByName('noarg')]]) {
        try {
          out[k] = await stub().hello();
        } catch (e) {
          out[k] = `${e.name}: ${e.message}`;
        }
      }
      return Response.json(out);
    }
    // 8f: the own names of the prototype of an exported class (`?class=`), or of the default export.
    if (path === '/__proto') {
      const C = exported[new URL(request.url).searchParams.get('class')] ?? Handler;
      return Response.json(Object.getOwnPropertyNames(C.prototype).sort());
    }
    const w0 = r.x.task_waits();
    const c0 = { ...r.stats.crossings };
    const t0 = Date.now();
    const res = await super.fetch(request);
    const out = new Response(res.body, res);
    out.headers.set('x-waits', String(r.x.task_waits() - w0));
    out.headers.set('x-awaits', String(r.stats.crossings.await - c0.await));
    out.headers.set('x-calls', String(r.stats.crossings.call - c0.call));
    out.headers.set('x-ms', String(Date.now() - t0));
    return out;
  }
  // 8f: JS callees of the RPC checks. MC5: the JS kinds of the fields of the argument (a `Cbor.Bytes` field is a
  // `Uint8Array`, a `List(U8)` field an `Array`). The RPC limit: a text of `n` bytes. A reply is a `Reply` of `Rpc.roc`: `{ Ok: value }`.
  inspect(arg) {
    return { Ok: { data: kind(arg?.data), list: kind(arg?.list) } };
  }
  big(arg) {
    return { Ok: 'x'.repeat(Number(arg.n)) };
  }
}
