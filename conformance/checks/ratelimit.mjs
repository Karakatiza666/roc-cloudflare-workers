// `RateLimit` (MODULES.md 10): routes of conformance/RateLimitRoutes.roc, on the local rate limit binding of Miniflare.
import { answer, ok } from '../assert.mjs';

export const options = {
  ratelimits: { LIMITER: { namespace_id: '1001', simple: { limit: 2, period: 60 } } },
};

// Local form: the third call within the period is `RateLimited`. Edge form (`t.edge`, PLAN.md 11c, E23): the limit is per
// location and not exact (Cloudflare docs), so the third call is `Ok` or `RateLimited`. The first two are `Ok` on a new key only.
async function third(t, path) {
  const r = await t.get(path);
  if (t.edge) ok(r.status === 200 && (r.body === 'Ok' || r.body === 'RateLimited'), `got ${r.status} ${r.body}, want Ok or RateLimited (edge form)`);
  else answer(r, 'RateLimited');
}

export const checks = [
  ['ratelimit limit!', async (t) => {
    answer(await t.get('/ratelimit/limit?key=a'), 'Ok');
    answer(await t.get('/ratelimit/limit?key=a'), 'Ok');
    await third(t, '/ratelimit/limit?key=a');
    answer(await t.get('/ratelimit/limit?key=b'), 'Ok');
  }],
  ['ratelimit limit (Io twin)', async (t) => {
    answer(await t.get('/ratelimit/limit_io?key=c'), 'Ok');
    answer(await t.get('/ratelimit/limit_io?key=c'), 'Ok');
    await third(t, '/ratelimit/limit_io?key=c');
  }],
  ['ratelimit: no binding is LimitErr', async (t) => answer(await t.get('/ratelimit/missing?key=a'), 'LimitErr TypeError')],
];
