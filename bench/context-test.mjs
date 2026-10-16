// PLAN.md 9b: the context of a task. No workerd (the workerd version is bench/context-workerd.mjs).
// node bench/context-test.mjs bench/out/app.wasm
// 50 requests at once, each with its own header `x-ctx-id`, `env` and `ctx`. Each op of the app gets the roots
// `env`, `ctx` and `event` of its task (bench/app.roc `effect!`, API.md 6.2 OP3; until 8a: the task id, and the op
// read the context from the task table). Its answer comes from the header, so the body is right only when each
// effect saw the headers of its own request. Also: each effect sees the `env`, `ctx` and request object of its own
// request, the task of that request has an own `Refs` table with one ref in it (the request body, a stream since
// PLAN.md 10a), and the task table is empty at the end. Both variants.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeHandler } from './cf-node.mjs';
import { check } from './check.js';
import { Refs } from '../js/values.js';
import { benchOps } from './ops.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

for (const variant of ['a', 'b']) {
  const N = 50;
  const envs = new Map();
  const ctxs = new Map();
  const reqs = new Map();
  const tables = new Set();
  let effects = 0;
  let wrong = 0;
  let inFlight = 0;
  let maxInFlight = 0;
  const taskOf = (event) => {
    for (let i = 1; i <= Handler.runner.tasks.stats.started; i++) if (Handler.runner.tasks.get(i)?.event === event) return Handler.runner.tasks.get(i);
    return null;
  };
  const io = async (kind, a, b, c) => {
    const t = taskOf(c.event);
    const id = c.event.headers.get('x-ctx-id');
    // The arguments of the call name the request that made it.
    const mine = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    effects++;
    if (id !== mine) wrong++;
    if (c.env !== envs.get(mine) || c.ctx !== ctxs.get(mine) || c.event !== reqs.get(mine)) wrong++;
    // One ref: the request body, a stream (PLAN.md 10a). The app read it before its ops.
    if (!t || !(t.refs instanceof Refs) || t.refs.size !== 1) wrong++;
    tables.add(t?.refs);
    inFlight++;
    maxInFlight = Math.max(maxInFlight, inFlight);
    await sleep(kind === 1 ? 5 : 1);
    inFlight--;
    return `${kind === 1 ? 'f' : 'd'}:${id}`;
  };
  // Since 8b `makeHandler` gives a class: one instance for each request, with its `ctx` and `env` (as Workers does).
  const Handler = makeHandler(module, { variant, ops: benchOps(io), isolateBytes: 2 ** 40 });
  const ids = Array.from({ length: N }, (_, i) => `req${i}`);
  const res = await Promise.all(
    ids.map((id) => {
      const env = { id };
      const ctx = { id, waitUntil() {} };
      const req = new Request('http://x/', { method: 'POST', body: `${id} 0 5`, headers: { 'x-ctx-id': id } });
      envs.set(id, env);
      ctxs.set(id, ctx);
      reqs.set(id, req);
      return new Handler(ctx, env).fetch(req).then((r) => r.text());
    }),
  );
  const badBody = ids.filter((id, i) => !check(id, res[i], 5));
  console.log(variant, { effects, maxInFlight, wrong, badBody: badBody.length, tables: tables.size, left: Handler.runner.tasks.size });
  if (effects !== 2 * N) fail(`${variant}: want ${2 * N} effects, got ${effects}`);
  if (maxInFlight < 2) fail(`${variant}: the requests did not overlap`);
  if (wrong) fail(`${variant}: ${wrong} effects saw an env, ctx, request or ref table of another task`);
  if (badBody.length) fail(`${variant}: ${badBody.length} bodies show the headers of another request, first: ${badBody[0]}: ${res[ids.indexOf(badBody[0])]?.slice(-40)}`);
  if (tables.size !== N) fail(`${variant}: the ref tables are not one for each task (${tables.size})`);
  if (Handler.runner.tasks.size !== 0) fail(`${variant}: the task table is not empty at the end`);
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
