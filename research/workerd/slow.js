const log = [];
export default {
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/log') return Response.json(log);
    const id = u.searchParams.get('id');
    log.push({ id, what: 'slow-start', t: Date.now() });
    req.signal?.addEventListener('abort', () => log.push({ id, what: 'slow-signal-abort', t: Date.now() }));
    await new Promise((r) => setTimeout(r, Number(u.searchParams.get('ms'))));
    log.push({ id, what: 'slow-end', t: Date.now() });
    return new Response('slow ' + id);
  },
};
