// The entry service of bench/config-entry.capnp (PLAN.md 8b, bench/entry-workerd.mjs). Miniflare is not installed, so
// this worker serves `GET /cdn-cgi/local/scheduled?cron=<cron>&time=<ms>&format=json` as Miniflare does
// (miniflare/src/workers/core/scheduled.ts): `env.APP.scheduled({ scheduledTime, cron })` through a service binding
// with the flag `service_binding_extra_handlers`, then `{ outcome, noRetry }`, status 200 for "ok", else 500.
// `GET /queue` sends a queue event with one message (`env.APP.queue`). Each other request goes to the app.
export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    if (u.pathname === '/cdn-cgi/local/scheduled') {
      const time = u.searchParams.get('time');
      const result = await env.APP.scheduled({ scheduledTime: time ? new Date(parseInt(time)) : undefined, cron: u.searchParams.get('cron') ?? undefined });
      const status = result.outcome === 'ok' ? 200 : 500;
      return u.searchParams.get('format') === 'json' ? Response.json(result, { status }) : new Response(result.outcome, { status });
    }
    if (u.pathname === '/queue') {
      const result = await env.APP.queue('jobs', [{ id: 'm1', timestamp: new Date(1_700_000_000_000), body: 'hi', attempts: 1 }]);
      return Response.json(result);
    }
    return env.APP.fetch(req);
  },
};
