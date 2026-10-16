// PLAN.md 3, open point "a wait that never settles after respond! while a stream is open" (8b, second half).
// GET /stream?id=&n=&gap=: a response with the readable side of a TransformStream. A loop in ctx.waitUntil writes
// n chunks of 1 KB, one each `gap` ms. It records: the abort of request.signal, the rejection of writer.closed (the
// readable side was cancelled), a write that rejects, and the end of the loop.
// GET /stream-nowait: the same loop with no waitUntil.
// GET /timer?id=&wait=0|1: a timer of 100 ms after the response, with or without ctx.waitUntil. It records "fired".
// GET /events?id=: the records of id.
const events = new Map();
const rec = (id, what) => {
  if (!events.has(id)) events.set(id, { t0: Date.now(), list: [] });
  const e = events.get(id);
  e.list.push(`${Date.now() - e.t0}ms ${what}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export default {
  async fetch(req, env, ctx) {
    const u = new URL(req.url);
    const id = u.searchParams.get('id') ?? '-';
    if (u.pathname === '/events') return Response.json(events.get(id)?.list ?? []);
    if (u.pathname === '/timer') {
      rec(id, 'start');
      const p = sleep(100).then(() => rec(id, 'fired'));
      if (u.searchParams.get('wait') === '1') ctx.waitUntil(p);
      return new Response('ok');
    }
    if (u.pathname === '/after') {
      // A complete body, then 1 s of work in waitUntil. Does the signal abort when the client goes away after the body?
      rec(id, 'start');
      req.signal?.addEventListener('abort', () => rec(id, 'signal abort'));
      ctx.waitUntil(sleep(1000).then(() => rec(id, 'work end')));
      return new Response('done');
    }
    if (u.pathname === '/stream' || u.pathname === '/stream-nowait') {
      const n = Number(u.searchParams.get('n') ?? 50);
      const gap = Number(u.searchParams.get('gap') ?? 100);
      rec(id, `start signal=${typeof req.signal} aborted=${req.signal?.aborted}`);
      req.signal?.addEventListener('abort', () => rec(id, 'signal abort'));
      const ts = new TransformStream();
      const w = ts.writable.getWriter();
      w.closed.then(() => rec(id, 'closed ok'), (e) => rec(id, `closed rejected: ${e?.name ?? e}: ${String(e?.message ?? '').slice(0, 60)}`));
      const loop = (async () => {
        const chunk = new Uint8Array(1024).fill(97);
        for (let i = 0; i < n; i++) {
          try {
            await w.write(chunk);
          } catch (e) {
            rec(id, `write ${i} rejected: ${e?.name}: ${String(e?.message).slice(0, 60)}`);
            return;
          }
          await sleep(gap);
        }
        await w.close().catch(() => {});
        rec(id, 'loop end');
      })();
      if (u.pathname === '/stream') ctx.waitUntil(loop);
      return new Response(ts.readable, { headers: { 'content-type': 'application/octet-stream' } });
    }
    return new Response('not found', { status: 404 });
  },
};
