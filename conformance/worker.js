// The worker of the conformance app (PLAN.md 8c) in Miniflare: `app.wasm` (conformance/app.roc on the bench platform)
// behind `makeHandler`. Each response has the waits of its task (`x-waits`, the bench export `task_waits`) and its time
// in ms (`x-ms`), and its crossings (`x-awaits`, `x-calls`: the calls of `js_await` and `js_call`, from `stats.crossings`
// of the runner): `run.mjs` sends one request at a time. `GET /__stats`: the task table. `GET /__mem`: the size of wasm memory in bytes (10a).
import app from 'app.wasm';
import { makeHandler, objectClass, entrypointClass } from './js/index.js';
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
const exported = { Counter, Store, Flaky, Slow, Ticker, KvOnly, Admin };
const kind = (v) => (v === null ? 'null' : Array.isArray(v) ? 'Array' : typeof v === 'object' ? Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto' : typeof v);

// The root `ops` (API.md 6.4). `lib` is an object of functions, not a function (the option check, PLAN.md 8a O4).
const ops = {
  lib: { twice: (n) => n * 2 },
};
// `tailMaxBytes`: 100 kB, so a trace with the logs of 2 MiB (cut by workerd to 200 kB) is above the limit (checks/tail.mjs).
// `initMs`: the `Init` deadline of API.md 10.2, smaller for the test (class `Slow`).
const Handler = makeHandler(app, { ops, heapCheckWhenIdle: false, tailMaxBytes: 100_000, initMs: 1000 });

// The messages that the JS consumer of the queue `v8` got (PLAN.md 8f): a `Queue.v8` message with a `Cbor.Bytes` field is
// a `Uint8Array` here, and a `U64` of 2^60 is a `BigInt`. `GET /__queue_seen` gives them.
const seen = [];

export default class extends Handler {
  async queue(batch) {
    if (batch.queue !== 'v8') return super.queue(batch);
    for (const m of batch.messages) {
      const b = m.body;
      seen.push({ id: m.id, n: b.n, big: `${typeof b.big} ${String(b.big)}`, isUint8Array: b.data instanceof Uint8Array, data: b.data instanceof Uint8Array ? [...b.data] : b.data });
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
    if (path === '/__mem') return new Response(String(r.x.memory.buffer.byteLength));
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
  // `Uint8Array`, a `List(U8)` field an `Array`). The RPC limit: a text of `n` bytes.
  inspect(arg) {
    return { data: kind(arg?.data), list: kind(arg?.list) };
  }
  big(arg) {
    return 'x'.repeat(Number(arg.n));
  }
}
