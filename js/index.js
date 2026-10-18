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
//   js/manifest.js the check of the manifest of the app
//   js/bindings.js the binding kinds of the manifest: the check of `env`, the Wrangler config parts
//   js/cli.js      the command `roc-cloudflare-workers` (sync, init)
// `cloudflare:workers` resolves in workerd and in Wrangler. In Node, a test registers a resolve hook to a stand-in class
// (`bench/cf-node.mjs`, `bench/cf-workers-stub.mjs`).
import { WorkerEntrypoint, DurableObject } from 'cloudflare:workers';
// `cf.env`: the env at global scope (workerd). The Node stand-in has none: the check of the bindings waits for an event.
import * as cf from 'cloudflare:workers';
import { bindingProblems } from './bindings.js';
import { checkManifest, RESERVED } from './manifest.js';
import { checkOptions } from './options.js';
import { makeRunner, manifestOf, NOT_STACK_FIRST } from './runner.js';
import { fetchEvent, scheduledEvent, queueEvent, emailEvent, tailEvent, otherEvent, responseOf, rpcEvent, entrypointFetchEvent, objectEvent, objectInit, objectFetch, objectAlarm, objectRpc, objectSocketMessage, objectSocketClose, objectSocketError, manifestEvent } from './events.js';
import { isBenchHost } from './host.js';
import { DEADLINES } from './tasks.js';

// The classes of the entry file (PLAN.md 8f, API.md AQ10): `objectClass` and `entrypointClass` make a class for each
// name, and `makeHandler` checks the names against the manifest of the app and puts the methods on each prototype.
// `app`: the last `makeHandler` (one in a Worker).
const classes = { objects: new Map(), entrypoints: new Map(), app: null };
const KINDS = { objects: 'objectClass', entrypoints: 'entrypointClass' };

// A Durable Object class of `Object.class(name, ...)` in Roc: `export const Room = objectClass("Room")`. Its methods come
// from the manifest at `makeHandler`, so the export lines come before `export default makeHandler(...)`.
export function objectClass(name) {
  return register('objects', name, () => {
    const C = class extends DurableObject {
      // SQLite-backed classes only (MODULES.md 7): a KV-backed class throws at its first event, with the name of the class.
      // A class with `init!` runs it in `blockConcurrencyWhile` (the event `Init`, API.md 10.1).
      constructor(ctx, env) {
        super(ctx, env);
        if (C.refused) throw new Error(C.refused);
        if (!C.app) throw new Error(`objectClass("${name}"): no makeHandler bound this class`);
        try {
          void ctx.storage.sql.databaseSize;
        } catch (e) {
          throw new Error(`Durable Object class ${name}: the platform needs a SQLite-backed class: put "${name}" in new_sqlite_classes (not new_classes) of the migrations in the Wrangler config. Workers: ${e.message}`);
        }
        if (C.handlers.has('init')) ctx.blockConcurrencyWhile(() => C.app.objectInit(name, ctx, env));
      }
    };
    return C;
  });
}

// A named entry point of `Rpc.entrypoint(name, ...)` in Roc: `export const Admin = entrypointClass("Admin")`.
export function entrypointClass(name) {
  return register('entrypoints', name, () => class extends WorkerEntrypoint {});
}

function register(kind, name, make) {
  if (typeof name !== 'string' || !/^[A-Za-z_$][\w$]*$/.test(name)) throw new TypeError(`${KINDS[kind]}: the name must be a JS name, got ${JSON.stringify(name)}`);
  if (classes.objects.has(name) || classes.entrypoints.has(name)) throw new Error(`${KINDS[kind]}("${name}"): a class of this name exists already`);
  const C = make();
  Object.defineProperty(C, 'name', { value: name });
  classes[kind].set(name, C);
  classes.app?.bind(kind, name, C);
  return C;
}

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
    checkEnv(ro.env);
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

  // PLAN.md 8f. The manifest of the app (API.md AQ10): the RPC methods of the default export, the Durable Object classes
  // and the named entry points, each with its handlers and methods. It runs now, at load, so a class in Roc with no
  // export, or an export with no class in Roc, stops the load with its name (`wrangler deploy` fails).
  // `undefined`: the module is not stack-first, so it is not run; each event of it throws (PLAN.md 1b).
  const got = manifestOf(module, manifestEvent());
  const manifest = checkManifest(got ?? { objects: {}, entrypoints: {} });
  // MODULES.md 3: each binding of the manifest must be in `env` with its kind. At load when workerd gives `env` at
  // global scope, else at the first event of each `env` (the error of the load, as a throw of the event).
  const envChecked = new WeakSet();
  const envError = (env) => {
    const problems = bindingProblems(manifest.bindings, env);
    return problems.length ? new Error(`makeHandler: the bindings of the app (Worker.new bindings) are not in env:\n  ${problems.join('\n  ')}\nnpx roc-cloudflare-workers sync prints the parts of the Wrangler config to add.`) : null;
  };
  const loadEnv = cf.env;
  if (manifest.bindings.length && loadEnv && typeof loadEnv === 'object') {
    const e = envError(loadEnv);
    if (e) throw e;
  }
  function checkEnv(env) {
    if (!manifest.bindings.length || !env || typeof env !== 'object' || envChecked.has(env)) return;
    const e = envError(env);
    if (e) throw e;
    envChecked.add(env);
  }
  const initMs = runnerOpts.initMs ?? DEADLINES.initMs;
  // A JS method on the prototype, where Workers finds a handler and an RPC method (an own property gives "The RPC
  // receiver does not implement the method").
  const method = (C, name, fn) => Object.defineProperty(C.prototype, name, { configurable: true, writable: true, value: fn });
  // `Reply` gives its value to the caller: a `Reply` of `Rpc.roc`, `{ Ok: value }` or `{ Err: tag }`, so an `Err` of the handler
  // is a normal reply (MODULES.md 8). `Failed` (an argument that does not parse): a log line and a throw with the text,
  // so the caller gets `RpcErr` with it. Each other outcome and a trap: a log line and a throw.
  const reply = (tag, r) => {
    if (r.trap) throw new Error(`${tag}: ${r.cancelled ? `cancelled: ${r.cancelled}` : `trap ${r.trap}`}`);
    if (r.outcome.outcome === 'reply') return r.outcome.value;
    log(`${tag}: ${reason(r.outcome)}`);
    if (r.outcome.outcome === 'failed') throw new Error(r.outcome.message);
    throw new Error(`${tag}: ${reason(r.outcome)}`);
  };
  // `Done` ends the event. Each other outcome and a trap: a log line and a throw (`Init`: Workers resets the object and
  // the event that started it fails; `Alarm`: Workers runs the alarm again).
  const done = (tag, r) => {
    if (r.trap) throw new Error(`${tag}: ${r.cancelled ? `cancelled: ${r.cancelled}` : `trap ${r.trap}`}`);
    if (r.outcome.outcome === 'done') return;
    log(`${tag}: ${reason(r.outcome)}`);
    throw new Error(`${tag}: ${reason(r.outcome)}`);
  };
  // The `fetch` of a named entry point and of a Durable Object: as the `fetch` of the Worker, with the `respond` hook
  // of `Ctx.respond!` (API.md 10.2) and no `pass_through!`. After `respond!`, an entry point gives the rest of the task
  // to `ctx.waitUntil`; an object does not need it (`keep` false).
  const fetchLike = async (tag, kind, ev, request, self, keep) => {
    const hooks = { kind, ctx: self.ctx, respond: null, response: null, passThrough: false };
    const early = new Promise((resolve) => (hooks.respond = resolve));
    const running = run(tag, ev, { kind: 'Fetch', signal: request.signal, env: self.env, ctx: self.ctx, event: request, hooks });
    const r = await Promise.race([running, early]);
    if (hooks.response) {
      const rest = running.then((x) => {
        if (!x.trap && x.outcome.outcome !== 'respond') log(`${tag}: after respond: ${reason(x.outcome)}`);
      });
      if (keep) self.ctx?.waitUntil?.(rest);
      return hooks.response;
    }
    if (r.trap) return new Response(`trap ${r.trap}`, { status: r.status ?? 500 });
    if (r.outcome.outcome === 'respond') return responseOf(r.outcome);
    log(`${tag}: ${reason(r.outcome)}`);
    return new Response(null, { status: 500 });
  };
  const hooksOf = (kind, self) => ({ kind, ctx: self.ctx });
  const app = {
    // The event `Init` in `blockConcurrencyWhile`. Its deadline (API.md 10.2, shim option `initMs`): a timer sweeps the
    // task table then, so the cancel names the task before Workers resets the object (30 s).
    async objectInit(name, ctx, env) {
      const timer = setTimeout(() => runnerOf().tasks.sweep(), initMs + 50);
      try {
        const r = await run(`${name}.init`, objectEvent(name, ctx.id.toString(), objectInit()), { kind: 'Init', env, ctx, event: ctx, hooks: { kind: 'Init', ctx } });
        done(`${name}.init`, r);
      } finally {
        clearTimeout(timer);
      }
    },
    bind(kind, name, C) {
      const entry = manifest[kind][name];
      if (!entry) throw new Error(`makeHandler: the export ${name} (${KINDS[kind]}) has no class in the app: add ${kind === 'objects' ? 'Object.class' : 'Rpc.entrypoint'}("${name}", ...) to the field ${kind} of Worker`);
      C.app = app;
      C.handlers = new Set(entry.handlers);
      if (kind === 'objects') {
        if (C.handlers.has('fetch')) method(C, 'fetch', function (request) {
          return fetchLike(`${name}.fetch`, 'ObjectFetch', objectEvent(name, this.ctx.id.toString(), objectFetch(request)), request, this, false);
        });
        if (C.handlers.has('alarm')) method(C, 'alarm', async function (info) {
          const r = await run(`${name}.alarm`, objectEvent(name, this.ctx.id.toString(), objectAlarm(info)), { kind: 'Alarm', env: this.env, ctx: this.ctx, event: info, hooks: hooksOf('Alarm', this) });
          done(`${name}.alarm`, r);
        });
        for (const m of entry.methods) method(C, m, async function (arg) {
          const r = await run(`${name}.${m}`, objectEvent(name, this.ctx.id.toString(), objectRpc(m, arg)), { kind: 'Rpc', env: this.env, ctx: this.ctx, event: arg, hooks: hooksOf('Rpc', this) });
          return reply(`${name}.${m}`, r);
        });
        // The hibernation API (MODULES.md 12.1): a method only for a handler of the class. An `Err`, `Unhandled` and a
        // trap are a log line, not a throw (MODULES.md 12.1, "Errors").
        const socketEvent = (handler, make) => {
          if (C.handlers.has(handler)) method(C, handler, async function (ws, ...rest) {
            const tag = `${name}.${handler}`;
            const r = await run(tag, objectEvent(name, this.ctx.id.toString(), make(ws, ...rest)), { kind: 'Socket', env: this.env, ctx: this.ctx, event: ws, hooks: hooksOf('Socket', this) });
            if (!r.trap && r.outcome.outcome !== 'done') log(`${tag}: ${reason(r.outcome)}`);
          });
        };
        socketEvent('webSocketMessage', objectSocketMessage);
        socketEvent('webSocketClose', objectSocketClose);
        socketEvent('webSocketError', objectSocketError);
      } else {
        if (C.handlers.has('fetch')) method(C, 'fetch', function (request) {
          return fetchLike(`${name}.fetch`, 'EntrypointFetch', entrypointFetchEvent(name, request), request, this, true);
        });
        for (const m of entry.methods) method(C, m, rpcMethod(name, m));
      }
    },
  };
  // An RPC method of the default export ("default") or of a named entry point: the event `Rpc`.
  function rpcMethod(entrypoint, m) {
    const tag = entrypoint === 'default' ? m : `${entrypoint}.${m}`;
    return async function (arg) {
      const r = await run(tag, rpcEvent(entrypoint, m, arg), { kind: 'Rpc', env: this.env, ctx: this.ctx, event: arg, hooks: hooksOf('Rpc', this) });
      return reply(tag, r);
    };
  }
  // QO5 (PLAN.md 8f, part 2): `queue`, `email` and `tail` only for an app whose manifest has the handler, as `alarm` of
  // an object class. A module that is not stack-first keeps all three: each event throws the layout error (PLAN.md 1b).
  // An app with no `Worker` wrapper (a raw `event!`) answers `Unhandled` to `Manifest` (`got` is null): it keeps all
  // three too, so its `event!` gets these events (PLAN.md 8f, part 3).
  for (const h of ['queue', 'email', 'tail']) if (got && !manifest.handlers.includes(h)) delete Handler.prototype[h];
  for (const m of manifest.default) {
    if (RESERVED.has(m) || other.includes(m)) throw new Error(`makeHandler: the RPC method ${m} of the default export has the name of a handler`);
    method(Handler, m, rpcMethod('default', m));
  }
  for (const kind of ['objects', 'entrypoints']) {
    if (got === undefined) {
      for (const [, C] of classes[kind]) C.refused = NOT_STACK_FIRST;
      continue;
    }
    for (const name of Object.keys(manifest[kind])) {
      if (!classes[kind].has(name)) throw new Error(`makeHandler: the class ${name} of the app has no export: add \`export const ${name} = ${KINDS[kind]}("${name}")\` to the entry file, before makeHandler`);
    }
    for (const [name, C] of classes[kind]) app.bind(kind, name, C);
  }
  classes.app = app;
  return Handler;
}
