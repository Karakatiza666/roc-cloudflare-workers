// Bench worker. env.VARIANT: "a" (instance per request) or "b" (shared instance, stack copy).
// GET /h?id=<id>&trap=0|1&depth=<levels>[&items=<n>][&mb=<n>]   run the Roc handler. mb: hold n MB across the waits
// GET /replace              a replace of the instance (M1, the test of PLAN.md 4e)
// GET /stats                counters of this isolate (GET /reset zeroes the copy counters)
// GET /inst?n=<n>&pad=0|1   n x (new WebAssembly.Instance + init), for the instantiate cost
import app from 'app.wasm';
import appPad from 'app_pad.wasm';
import { makeHandler } from './js/index.js';
import { instanceA } from './js/runner.js';
import { readFlag } from './js/host.js';
import { expected } from './check.js';

let handler = null;

// Memory options of the shim (PLAN.md 4): the bindings ISOLATE_MB, RESERVE_MB, MAX_INSTANCE_MB, GRACE_MS, QUEUE_LIMIT.
function memoryOpts(env) {
  const o = {};
  if (env.ISOLATE_MB) o.isolateBytes = Number(env.ISOLATE_MB) * 2 ** 20;
  if (env.RESERVE_MB) o.jsReserveBytes = Number(env.RESERVE_MB) * 2 ** 20;
  if (env.MAX_INSTANCE_MB) o.maxInstanceBytes = Number(env.MAX_INSTANCE_MB) * 2 ** 20;
  if (env.GRACE_MS) o.graceMs = Number(env.GRACE_MS);
  if (env.QUEUE_LIMIT) o.queueLimit = Number(env.QUEUE_LIMIT);
  // 12f: the binding RESUME_CHECK ("off", "afterAlarm", "always"). Not set: the default of the shim.
  if (env.RESUME_CHECK) o.resumeCheck = env.RESUME_CHECK;
  return o;
}
let mismatch = 0;

// The ops of the bench app (bench/app.roc `effect!`, API.md 6.4). The roots `env`, `ctx` and `event` of the task come
// as the last arguments (PLAN.md 9b): the shim has no other context, and the bench keeps none (no `env` of the first
// request). The header of the request of the task goes to the echo (bench/context-workerd.mjs).
async function echo(url, env, event) {
  const ctxId = event.headers.get('x-ctx-id');
  const r = await env.ECHO.fetch(url, ctxId ? { headers: { 'x-ctx-id': ctxId } } : undefined);
  return await r.text();
}
const ops = {
  fetch: (method, url, env, ctx, event) => echo(url, env, event),
  db: (q, env, ctx, event) => echo('http://echo/d?q=' + encodeURIComponent(q), env, event),
};

// The text that the bench app reads from the header `x-bench-text` (PLAN.md 8b, 10a: `bench/app.roc` `event!`). `mb`: hold n MB
// across the waits. `items`: the length of the list of the handler (12f). Not set: the default of the app (200).
function requestText(req) {
  const u = new URL(req.url);
  const id = u.searchParams.get('id');
  const trap = u.searchParams.get('trap') === '1';
  const depth = u.searchParams.get('depth') || '50';
  const mb = u.searchParams.get('mb');
  const items = u.searchParams.get('items');
  return mb ? `${id} 0 ${depth} 10 - ${mb}` : `${id} ${trap ? 1 : 0} ${depth}${items ? ' ' + items : ''}`;
}

export default {
  async fetch(req, env, ctx) {
    const u = new URL(req.url);
    const pad = u.searchParams.get('pad') === '1';
    if (u.pathname === '/h' && env.VARIANT === 'j') {
      // Baseline with no wasm: the same two waits, the expected body.
      const id = u.searchParams.get('id');
      const e = expected(id, Number(u.searchParams.get('depth') || 50));
      const f = await (await env.ECHO.fetch(`http://echo/f?id=${id}`)).text();
      const d = await (await env.ECHO.fetch('http://echo/d?q=' + encodeURIComponent(`select ${id}`))).text();
      return new Response(`${e.prefix}json=0 sum=${e.sum} fetch=${f} db=${d}`);
    }
    if (u.pathname === '/h') {
      // request.signal: a cancel when the client goes away (PLAN.md 3b, flag enable_request_signal).
      // ctx: the idle check of 12e runs in ctx.waitUntil, after the response.
      handler ??= makeHandler(env.PAD === '1' ? appPad : app, { ...memoryOpts(env), variant: env.VARIANT, ops });
      // The same request with the text in the header `x-bench-text` (bench/app.roc): no body, so the app has no wait
      // for a body stream before its work (PLAN.md 10a), and the memory of a request at its first wait stays the
      // estimate of variant "a". Its signal follows the signal of the client request.
      const headers = new Headers(req.headers);
      headers.set('x-bench-text', requestText(req));
      const inner = new Request(req.url, { method: 'POST', headers, signal: req.signal });
      return new handler(ctx, env).fetch(inner);
    }
    const runner = handler?.runner;
    if (u.pathname === '/replace' && runner) {
      runner.replace('test');
      return Response.json({ dropped: runner.budget.droppedBytes });
    }
    if (u.pathname === '/stats') {
      const x = runner?.x;
      return Response.json({
        variant: env.VARIANT,
        ...runner?.stats,
        cancels: runner?.tasks.stats.byReason,
        queueNow: runner?.queued,
        liveCount: runner?.budget.liveCount,
        budget: runner && {
          ...runner.budget.stats, total: runner.budget.total(), limit: runner.budget.limit, dropped: runner.budget.droppedBytes, droppedCount: runner.budget.droppedCount,
        },
        // M11, H3: the counters of the host for the current instance.
        host: x && runner.counters(),
        heap_used: x?.heap_used(),
        live_bytes: x?.live_bytes(),
        mem: x?.memory.buffer.byteLength,
        saved_max: x?.task_saved_max(),
        saved_peak: x?.task_saved_peak(),
        waits: x?.task_waits(),
        waiting: x?.task_waiting(),
        canary_ok: x?.stack_canary_ok(),
        // 5a: workerd zeroes the signal when it registers the instance. 0xFFFF: not registered.
        signal: x && (x.__instance_signal ? readFlag(x, '__instance_signal') : null),
        terminated: x && (x.__instance_terminated ? readFlag(x, '__instance_terminated') : null),
      });
    }
    if (u.pathname === '/reset') {
      runner?.x?.stats_reset();
      return new Response('ok');
    }
    if (u.pathname === '/inst') {
      const n = Number(u.searchParams.get('n') || 0);
      const m = pad ? appPad : app;
      let bytes = 0;
      for (let i = 0; i < n; i++) bytes += instanceA(m, null).memory.buffer.byteLength;
      return new Response(`ok ${n} ${bytes}`);
    }
    return new Response('not found', { status: 404 });
  },
};
