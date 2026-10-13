// Bench worker. env.VARIANT: "a" (instance per request) or "b" (shared instance, stack copy).
// GET /h?id=<id>&trap=0|1&depth=<levels>   run the Roc handler
// GET /stats                counters of this isolate (GET /reset zeroes the copy counters)
// GET /inst?n=<n>&pad=0|1   n x (new WebAssembly.Instance + init), for the instantiate cost
import app from 'app.wasm';
import appPad from 'app_pad.wasm';
import { makeRunner, instanceA, expected } from 'core.js';

let runner = null;
let mismatch = 0;

function io(env) {
  return async (kind, a, b) => {
    const url = kind === 1 ? b : 'http://echo/d?q=' + encodeURIComponent(a);
    const r = await env.ECHO.fetch(url);
    return await r.text();
  };
}

export default {
  async fetch(req, env) {
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
      runner ??= makeRunner(env.PAD === '1' ? appPad : app, env.VARIANT, io(env));
      const id = u.searchParams.get('id');
      const trap = u.searchParams.get('trap') === '1';
      const depth = u.searchParams.get('depth') || '50';
      const r = await runner.run(`${id} ${trap ? 1 : 0} ${depth}`);
      if (r.trap) return new Response('trap ' + r.trap, { status: 500 });
      return new Response(r.body);
    }
    if (u.pathname === '/stats') {
      const x = runner?.x;
      return Response.json({
        variant: env.VARIANT,
        ...runner?.stats,
        heap_used: x?.heap_used(),
        live_bytes: x?.live_bytes(),
        mem: x?.memory.buffer.byteLength,
        saved_max: x?.task_saved_max(),
        saved_peak: x?.task_saved_peak(),
        waits: x?.task_waits(),
        waiting: x?.task_waiting(),
        canary_ok: x?.stack_canary_ok(),
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
