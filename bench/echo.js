// The echo service binding: /f answers after 5 ms, /d (the "db") after 1 ms.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The header x-ctx-id (bench/context-workerd.mjs, PLAN.md 9b) replaces the id in the answer: it shows which request's
// context the shim gave to the effect.
export default {
  async fetch(req) {
    const u = new URL(req.url);
    const ctxId = req.headers.get('x-ctx-id');
    if (u.pathname === '/f') {
      // An id "hang..." answers after 10 min: a wait that does not settle (bench/signal-workerd.mjs).
      await sleep((u.searchParams.get('id') ?? '').startsWith('hang') ? 600_000 : 5);
      return new Response('f:' + (ctxId ?? u.searchParams.get('id')));
    }
    await sleep(1);
    return new Response('d:' + (ctxId ?? (u.searchParams.get('q') || '').split(' ')[1]));
  },
};
