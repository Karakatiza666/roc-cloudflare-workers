// The hooks module of test-helper/helper-test.mjs (TH7): a count of the events of each kind (H6), and two JS routes.
import { tag } from './tag.js';

const kinds = {};
export function wrapEnv(env, info) {
  kinds[info.kind] = (kinds[info.kind] ?? 0) + 1;
  return env;
}
export async function fetch(request, env, next) {
  const path = new URL(request.url).pathname;
  if (path === '/__kinds') return Response.json(kinds);
  if (path === '/__hook') {
    console.log(`hook log ${tag}`);
    await env.KV.get('hook');
    return new Response(`hook ${tag}`);
  }
  return next();
}
