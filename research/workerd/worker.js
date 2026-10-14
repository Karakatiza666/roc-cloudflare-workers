// Experiment worker for PLAN.md 3.0. All events go to a global log with Date.now().
import mod from 'm.wasm';
import big from 'big.wasm';
const log = [];
const ev = (id, what, extra) => log.push({ id, what, t: Date.now(), ...extra });
const fr = typeof FinalizationRegistry === 'function' ? new FinalizationRegistry((tag) => ev(tag, 'finalized')) : null;
let cur = null;
const get = new WebAssembly.Suspending(async () => {
  const c = cur;
  const token = { c: c.id };
  fr?.register(token, c.id + ':token');
  await body(c);
  token.done = 1;
  return 1;
});
async function body(c) {
  if (c.kind === 'timer') { await new Promise((r) => setTimeout(r, c.ms)); ev(c.id, 'io-settled'); }
  else if (c.kind === 'fetch') {
    try { const r = await c.env.SLOW.fetch('http://slow/?ms=' + c.ms + '&id=' + c.id); await r.text(); ev(c.id, 'io-settled'); }
    catch (e) { ev(c.id, 'io-rejected', { err: String(e) }); throw e; }
  } else if (c.kind === 'never') await new Promise(() => {});
  else if (c.kind === 'cancelable') {
    // Never settles by itself. GET /cancel rejects it from another (live) request.
    try { await new Promise((_, rej) => cancels.set(c.id, rej)); }
    catch (e) { ev(c.id, 'cancel-seen'); throw e; }
  }
}
let shared = null;
const instance = (m = mod) => { const i = new WebAssembly.Instance(m, { env: { get } }); if (m === big) new Uint8Array(i.exports.mem.buffer).fill(1); return { i, run: WebAssembly.promising(i.exports.run) }; };
const held = [];
const cancels = new Map();
export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    const q = (k, d) => u.searchParams.get(k) ?? d;
    if (u.pathname === '/wait') {
      const id = q('id'), kind = q('kind', 'timer'), ms = Number(q('ms', '3000')), tm = Number(q('tm', '0'));
      const mode = q('mode', 'shared');
      ev(id, 'start', { signal: !!req.signal });
      req.signal?.addEventListener('abort', () => ev(id, 'signal-abort'));
      if (tm) setTimeout(() => ev(id, 'req-timer'), tm);
      const c = { id, kind, ms, env };
      try {
        if (mode === 'js') { await body(c); }
        else {
          const x = mode === 'big' ? instance(big) : mode === 'fresh' ? instance() : (shared ??= instance());
          if (mode === 'fresh' || mode === 'big') fr?.register(x.i, id + ':instance');
          cur = c;
          await x.run();
        }
        ev(id, 'resumed');
      } catch (e) { ev(id, 'run-rejected', { err: String(e) }); }
      return new Response('done ' + id);
    }
    if (u.pathname === '/log') return Response.json({ now: Date.now(), fr: !!fr, weakref: typeof WeakRef, perfMemory: typeof performance.memory, measureUA: typeof performance.measureUserAgentSpecificMemory, process: typeof process, memUsage: (() => { try { return JSON.stringify(process.memoryUsage?.()); } catch (e) { return String(e); } })(), gc: typeof gc, log });
    if (u.pathname === '/gc') { if (typeof gc === 'function') gc(); return new Response('gc ' + typeof gc); }
    if (u.pathname === '/mem') {
      // A dropped instance with `mb` MB of memory (a Memory object, touched so pages are real).
      const id = q('id'), mb = Number(q('mb', '30'));
      const m = new WebAssembly.Memory({ initial: mb * 16 });
      new Uint8Array(m.buffer).fill(1);
      fr?.register(m, id + ':mem');
      ev(id, 'mem-dropped');
      if (q('hold') === '1') held.push(m);
      return new Response('mem ' + id);
    }
    if (u.pathname === '/load') {
      // JS garbage, as a busy request makes.
      let a = [];
      for (let i = 0; i < Number(q('n', '2000')); i++) a.push({ i, s: 'x' + i });
      await new Promise((r) => setTimeout(r, Number(q('ms', '5'))));
      return new Response('load ' + a.length);
    }
    if (u.pathname === '/cancel') {
      const pre = q('pre', ''); let n = 0;
      for (const [id, rej] of cancels) if (id.startsWith(pre)) { rej(new Error('cancelled')); cancels.delete(id); n++; }
      return new Response('cancelled ' + n);
    }
    if (u.pathname === '/slowlog') return env.SLOW.fetch('http://slow/log');
    return new Response('not found', { status: 404 });
  },
};
