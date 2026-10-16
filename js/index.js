// The JS shim of the platform (PLAN.md 9). One entry: `makeHandler(module, opts)`.
//   js/index.js    this file: the class of the default export
//   js/events.js   the events of API.md 10.1 as JS values, and the outcome back to Workers
//   js/options.js  the options, checked at `makeHandler` time
//   js/runner.js   instances, tasks, alarm and check paths
//   js/wait.js     the cancel of a task
//   js/bridge.js   the imports js_await and js_call (API.md 4.1)
//   js/program.js  the program interpreter (API.md 6.2)
//   js/helpers.js  the root `pf` and the pin table (API.md 6.4)
//   js/values.js   JS values to `Js` bytes and back (API.md 5)
//   js/cbor.js     the CBOR profile (API.md 5)
//   js/host.js     readers and constants of the host exports
//   js/tasks.js    the task table and the context of each task
//   js/budget.js   the memory budget of the isolate
// `cloudflare:workers` resolves in workerd and in Wrangler. In Node, a test registers a resolve hook to a stand-in class
// (`bench/cf-node.mjs`, `bench/cf-workers-stub.mjs`).
import { WorkerEntrypoint } from 'cloudflare:workers';
import { checkOptions } from './options.js';
import { makeRunner } from './runner.js';
import { fetchEvent, scheduledEvent, queueEvent, emailEvent, tailEvent, otherEvent, responseOf } from './events.js';
import { isBenchHost } from './host.js';

// `module`: the compiled app (a `WebAssembly.Module`). Gives the class of the default export of the Worker: a subclass of
// `WorkerEntrypoint`, so Workers sends RPC to it (API.md 10.1). Its `fetch` and `scheduled` methods, and one method for
// each name of `opts.other`, send the events of API.md 10.1, with `this.env` and `this.ctx` as the roots `env` and `ctx`.
// Throws for an unknown option, a bad value, or `resumeCheck: "off"` on a production host (it has no bench export,
// PLAN.md 7a). So a wrong setup fails at load, not at the first request.
// `opts.ops`: the JS functions of the app (API.md 6.4). The class has the static `runner` for tests and the bench.
export function makeHandler(module, opts = {}) {
  if (!(module instanceof WebAssembly.Module)) throw new TypeError('makeHandler: module must be a WebAssembly.Module');
  const { other = [], tailMaxBytes, ...runnerOpts } = checkOptions(opts);
  const log = runnerOpts.log ?? ((text) => console.warn(text));
  // workerd forbids random values at global scope (the free mark of an instance, `freeMark`), and the default export
  // is made there. So the runner and its first instance start at the first use (an event, or a read of `runner`), and
  // `resumeCheck: "off"` on a production host throws now by the export list of the module (PLAN.md 7a). The runner
  // checks it again with `set_sum` at the first instance.
  if (runnerOpts.resumeCheck === 'off' && !isBenchHost(module)) throw new Error('resumeCheck "off" needs the bench host: the production host refuses it');
  let runner = null;
  const runnerOf = () => (runner ??= makeRunner(module, runnerOpts));

  // Run one event as a task. A trap gives `{ trap, status }`; its log line has the text of a Roc `crash` (8a O2).
  // `ro`: the task context (PLAN.md 9b, API.md 6.2 OP3): `kind`, `signal`, `env`, `ctx` and `event` (the root `event`).
  const run = async (name, ev, ro) => {
    const r = await runnerOf().run(ev, ro);
    if (r.trap && !r.shed && !r.cancelled) log(`${name}: trap: ${r.crash ?? r.trap}`);
    return r;
  };
  // An outcome that the entry does not take: the reason as text (API.md 10.1: `Failed`, `Unhandled`, another one).
  const reason = (o) => (o.outcome === 'failed' ? `failed: ${o.message}` : o.outcome === 'unhandled' ? 'unhandled: the app has no handler for it' : `the outcome ${o.outcome} is not for this event`);

  // After `Ctx.respond!` the response is out: the outcome of the task is not a response. A `Failed` or `Unhandled` is
  // a log line (a trap has its line from `run`).
  const after = (r) => {
    if (!r.trap && r.outcome.outcome !== 'respond') log(`fetch: after respond: ${reason(r.outcome)}`);
  };

  class Handler extends WorkerEntrypoint {
    // `Respond` gives the response. `Failed`, `Unhandled`: a log line and a 500 response with no body.
    // A trap: a response with `trap ...` and the status of the runner (500, or 503 for a shed, a cancel, OOM).
    // `Ctx.respond!` (API.md 10.2): its response goes to Workers at once, and the rest of the task runs in
    // `ctx.waitUntil`. After `Ctx.pass_through!`, a `Failed` and a trap are a throw: Workers sends the request to the
    // origin (API.md 10.1).
    async fetch(request) {
      const hooks = { kind: 'Fetch', ctx: this.ctx, respond: null, response: null, passThrough: false };
      const early = new Promise((resolve) => (hooks.respond = resolve));
      const running = run('fetch', await fetchEvent(request), { kind: 'Fetch', signal: request.signal, env: this.env, ctx: this.ctx, event: request, hooks });
      const r = await Promise.race([running, early]);
      if (hooks.response) {
        this.ctx?.waitUntil?.(running.then(after));
        return hooks.response;
      }
      if (r.trap) {
        if (hooks.passThrough && !r.shed && !r.cancelled) throw new Error(`fetch: trap ${r.trap}`);
        return new Response(`trap ${r.trap}`, { status: r.status ?? 500 });
      }
      if (r.outcome.outcome === 'respond') return responseOf(r.outcome);
      log(`fetch: ${reason(r.outcome)}`);
      if (hooks.passThrough && r.outcome.outcome === 'failed') throw new Error(`fetch: ${reason(r.outcome)}`);
      return new Response(null, { status: 500 });
    }

    // `Done`: a good run. Each other outcome and a trap: a log line and a throw, so the run fails (Past Events).
    // The shim never calls `controller.noRetry()` by itself: only `Worker.Scheduled.no_retry!` does (MODULES.md 3).
    async scheduled(controller) {
      const r = await run('scheduled', scheduledEvent(controller), { kind: 'Scheduled', env: this.env, ctx: this.ctx, event: controller, hooks: { kind: 'Scheduled', ctx: this.ctx } });
      if (r.trap) throw new Error(`scheduled: trap ${r.trap}`);
      if (r.outcome.outcome === 'done') return;
      log(`scheduled: ${reason(r.outcome)}`);
      throw new Error(`scheduled: ${reason(r.outcome)}`);
    }

    // `Queue` (API.md 10.1): `Done` leaves the messages with no ack or retry to the queue default. Each other outcome
    // and a trap: a log line and a throw, so Workers retries the batch. An explicit ack or retry stands.
    async queue(batch) {
      const r = await run('queue', queueEvent(batch), { kind: 'Queue', env: this.env, ctx: this.ctx, event: batch, hooks: { kind: 'Queue', ctx: this.ctx } });
      if (r.trap) throw new Error(`queue: trap ${r.trap}`);
      if (r.outcome.outcome === 'done') return;
      log(`queue: ${reason(r.outcome)}`);
      throw new Error(`queue: ${reason(r.outcome)}`);
    }

    // `Email` (API.md 10.1): `Done` accepts the mail. Each other outcome and a trap: a log line and a throw, so the mail is rejected.
    async email(message) {
      const r = await run('email', emailEvent(message), { kind: 'Email', env: this.env, ctx: this.ctx, event: message, hooks: { kind: 'Email', ctx: this.ctx } });
      if (r.trap) throw new Error(`email: trap ${r.trap}`);
      if (r.outcome.outcome === 'done') return;
      log(`email: ${reason(r.outcome)}`);
      throw new Error(`email: ${reason(r.outcome)}`);
    }

    // `Tail` (API.md 10.1): the batch with its log lines cut to 1 MiB (MC11). Each outcome but `Done` and a trap: a log line only.
    async tail(events) {
      const r = await run('tail', tailEvent(events, tailMaxBytes, log), { kind: 'Tail', env: this.env, ctx: this.ctx, event: events, hooks: { kind: 'Tail', ctx: this.ctx } });
      if (!r.trap && r.outcome.outcome !== 'done') log(`tail: ${reason(r.outcome)}`);
    }
  }
  // `Other` (API.md 10.1): a method on the prototype for each name of `opts.other`, as Workers finds a handler or an RPC
  // method there. `Reply` gives its value to the caller. Each other outcome and a trap: a log line and a throw.
  for (const name of other) {
    Object.defineProperty(Handler.prototype, name, {
      configurable: true,
      writable: true,
      value: async function (payload) {
        const r = await run(name, otherEvent(name, payload), { kind: 'Other', env: this.env, ctx: this.ctx, event: payload, hooks: { kind: 'Other', ctx: this.ctx } });
        if (r.trap) throw new Error(`${name}: trap ${r.trap}`);
        if (r.outcome.outcome === 'reply') return r.outcome.value;
        log(`${name}: ${reason(r.outcome)}`);
        throw new Error(`${name}: ${reason(r.outcome)}`);
      },
    });
  }
  // For tests and the bench: counters, the task table, the budget. A read starts the runner.
  Object.defineProperty(Handler, 'runner', { get: runnerOf });
  // 8f: `objectClass(name)` and `entrypointClass(name)`, the event `Manifest` (AQ10), RPC methods, `queue`, `email`, `tail`.
  return Handler;
}
