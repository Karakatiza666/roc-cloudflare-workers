// `RateLimit` (MODULES.md 10): routes of conformance/RateLimitRoutes.roc, on the local rate limit binding of Miniflare.
import { answer } from '../assert.mjs';

export const options = {
  ratelimits: { LIMITER: { namespace_id: '1001', simple: { limit: 2, period: 60 } } },
};

export const checks = [
  ['ratelimit limit!', async (t) => {
    answer(await t.get('/ratelimit/limit?key=a'), 'Ok');
    answer(await t.get('/ratelimit/limit?key=a'), 'Ok');
    answer(await t.get('/ratelimit/limit?key=a'), 'RateLimited');
    answer(await t.get('/ratelimit/limit?key=b'), 'Ok');
  }],
  ['ratelimit limit (Io twin)', async (t) => {
    answer(await t.get('/ratelimit/limit_io?key=c'), 'Ok');
    answer(await t.get('/ratelimit/limit_io?key=c'), 'Ok');
    answer(await t.get('/ratelimit/limit_io?key=c'), 'RateLimited');
  }],
  ['ratelimit: no binding is LimitErr', async (t) => answer(await t.get('/ratelimit/missing?key=a'), 'LimitErr TypeError')],
];
