// The worker of bench/bridge-workerd.mjs (PLAN.md 8a in workerd): bench/app_bridge.wasm with the ops of
// bench/bridge-test.mjs. GET /b?q=<request>: the body of the app. GET /stats: the counters of the bridge.
import app from 'app_bridge.wasm';
import { makeHandler } from './js/index.js';
import { benchEvent, benchBody } from './check.js';

let handler = null;
let aborts = [];
// A wait of `ms`. An abort before the end rejects it and is counted in `aborts` (with the text of its reason).
const sleep = (ms, signal) =>
  new Promise((res, rej) => {
    const onAbort = () => {
      clearTimeout(t);
      aborts.push(`${ms}: ${signal.reason?.message}`);
      rej(signal.reason);
    };
    const t = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      res(ms);
    }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
class Thing {}
const t1 = new Thing(), t2 = new Thing();
const ops = {
  // As a D1 binding: an object with methods (a function, so the shim option `ops` takes it).
  db: Object.assign(() => {}, { prepare: (sql) => ({ bind: (...a) => ({ raw: async () => [[sql, ...a]] }) }) }),
  thing: () => t1,
  other: () => t2,
  sleep,
  name: (n) => 'name-' + n,
  rows: (n) => Array.from({ length: n }, (_, i) => ({ id: i, name: 'pkg-' + i, version: '1.' + i })),
  messages: () => [{ id: 'a', body: 1 }, { id: 'b', body: 2 }],
  objs: (n) => Array.from({ length: n }, () => new Thing()),
  tick: (s) => sleep(1, s),
  // A long wait on a timer. A promise that never settles and has no timer is a hung request for workerd: it
  // cancels the request with no abort of `request.signal`, so the task would stay until the deadline sweep (3b).
  hang: () => sleep(60000),
  failAlloc: async () => {
    await sleep(1);
    handler.runner.x.fail_next_alloc();
    return 'x';
  },
};

export default {
  async fetch(req, env, ctx) {
    const u = new URL(req.url);
    handler ??= makeHandler(app, { ops });
    if (u.pathname === '/b') {
      const q = u.searchParams.get('q');
      const x = handler.runner.x;
      const w0 = x.task_waits();
      const t0 = Date.now();
      // PLAN.md 8b: the request text is the body of a `Fetch` event, and the answer is the body of the outcome.
      const r = await handler.runner.run(benchEvent(q), { signal: req.signal, ctx, env, event: req });
      const head = { 'x-waits': String(handler.runner.x.task_waits() - w0), 'x-ms': String(Date.now() - t0) };
      if (r.trap) return new Response(`trap ${r.status ?? ''} ${r.cause ?? r.alarm ?? ''} ${r.trap}`, { status: 503, headers: head });
      return new Response(benchBody(r.outcome), { headers: head });
    }
    if (u.pathname === '/aborts') {
      const a = aborts;
      aborts = [];
      return Response.json(a);
    }
    if (u.pathname === '/stats') {
      const s = handler.runner.tasks.stats;
      return Response.json({ refsLive: s.refsLive, contextsLive: s.contextsLive, live: handler.runner.x.live_bytes(), alarms: handler.runner.stats.alarms });
    }
    return new Response('not found', { status: 404 });
  },
};
