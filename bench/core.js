// The runtime of the platform is in js/ (PLAN.md 9a). This file gives the Node tests one import for
// its parts and for the test helpers of bench/check.js.
import { makeRunner as makeRunnerOf } from '../js/runner.js';
import { benchOps } from './ops.js';
import { benchEvent, benchBody } from './check.js';
import { encEvent, eventBytes, readOutcome } from '../js/host.js';
import { Refs } from '../js/values.js';
export * from '../js/runner.js';
export * from '../js/wait.js';
export * from '../js/host.js';
export * from './check.js';
export { benchOps };

// The runner of js/runner.js with the effects of a test: `io(kind, a, b, context)` becomes the ops `fetch` and
// `db` of the bench apps (bench/ops.js). opts.ops: more ops (they win over the two).
// PLAN.md 8b: `run(text, ro)` sends the text as the body of a `Fetch` event (`benchEvent`) and gives the body of the
// `Respond` outcome as `body` (text), as before 8b. An object is sent as the event itself.
export function makeRunner(module, variant, io, opts = {}) {
  const r = makeRunnerOf(module, variant, { ...opts, ops: { ...(io ? benchOps(io) : {}), ...opts.ops } });
  const run = r.run;
  r.run = async function (req, ro) {
    const res = await run.call(r, typeof req === 'string' ? benchEvent(req) : req, ro);
    return res.outcome ? { ...res, body: benchBody(res.outcome) } : res;
  };
  return r;
}

// For the tests that call `handle` with no runner (PLAN.md 8b): the text as a `Fetch` event in a js_alloc block
// ([ptr, len], null when out of memory), and the body of the outcome block as text (the block is freed).
export const eventBlock = (x, text) => encEvent(x, eventBytes(benchEvent(text), new Refs()));
export const outcomeBody = (x, blk) => benchBody(readOutcome(x, blk, new Refs()));
