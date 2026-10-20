// Task table of the JS shim (PLAN.md 3a, 3b, 3c). One entry for each task in flight.
// It knows no wasm: the runner (`runner.js`) starts and ends tasks, and the import wrapper
// (`js_await`, `bridge.js`) marks each wait and ends a cancelled task with status 5.
// Each entry also keeps the context of its task (9b): `env`, `ctx`, `event` (the request object) and `refs`
// (the ref table, API.md RS1). They are the roots of API.md 6.2 (OP3). The bridge finds them by task id (`pctx`:
// the context of its programs). At the end of the task (also a trap or a cancel), the table frees its refs and
// aborts its signal, or when its last started program settles (`spawnStart`, `spawnEnd`, API.md RS1, PLAN.md 10c),
// or at the `waitUntil` limit: `afterRespondMs` after the response is complete (9c, `sweep`).
// `hooks`: what the entry of the task gives to the platform helpers (`js/index.js`): `kind`, `ctx`, `respond` (only
// the `fetch` of a Worker: `Response.after`), and the flags that the helpers set (`response`, `passThrough`).

import { Refs } from './values.js';

// Deadlines of API.md 10.2. Shim options: a test can make them smaller.
export const DEADLINES = {
  taskDeadlineMs: 120_000, // each wait of a Fetch task before the response, and of a kind with no limit
  wallMs: 15 * 60_000, // the whole task: Scheduled, Queue, Alarm
  initMs: 30_000, // the whole task: Init of an object
  afterRespondMs: 30_000, // after the response body is complete (the waitUntil limit)
};

// Kinds with a wall time limit for the whole task, and no deadline for one wait.
const WALL = new Set(['Scheduled', 'Queue', 'Alarm']);

// The time at which task `t` must be cancelled, or Infinity (API.md 10.2). Pure.
// response: 'none' (no response yet), 'open' (a response with a Body.writer! stream that
// is not closed, or a 101 with an open socket), 'complete' (at `completeAt`).
export function deadlineOf(t, d = DEADLINES) {
  if (t.waiting && t.socketWait) return Infinity;
  if (t.response === 'complete') return t.completeAt + d.afterRespondMs;
  if (t.response === 'open') return Infinity;
  if (WALL.has(t.kind)) return t.startedAt + d.wallMs;
  if (t.kind === 'Init') return t.startedAt + d.initMs;
  return t.waiting ? t.waitingSince + d.taskDeadlineMs : Infinity;
}

// The time at which the context of an ended task `t` is freed, although a started program still runs: the `waitUntil`
// limit, `afterRespondMs` after the response is complete. A task that ended with no complete response (no early response, or
// a writer that the end closed) has it complete at its end. Pure.
export function lingerUntil(t, d = DEADLINES) {
  return (t.response === 'complete' ? Math.min(t.completeAt, t.endedAt) : t.endedAt) + d.afterRespondMs;
}

// opts: the DEADLINES keys, `now` (a clock for tests), `onCancel(t)`: called at the cancel
// of a task that waits (the runner frees it in the host there, PLAN.md 3c), `log(text)`: one line
// for each cancel (M11).
export function makeTaskTable(opts = {}) {
  const d = { ...DEADLINES };
  for (const k of Object.keys(DEADLINES)) if (opts[k] !== undefined) d[k] = opts[k];
  const now = opts.now ?? (() => Date.now());
  const tasks = new Map();
  const live = new Map(); // instance -> tasks in flight
  // refsLive: refs in the tables of the tasks (RS1); 0 when no task is in flight and no started program runs.
  // contextsExpired: contexts of ended tasks that the `waitUntil` limit freed while a started program ran (9c).
  const stats = { started: 0, shed: 0, cancels: 0, byReason: {}, refsLive: 0, contextsLive: 0, contextsExpired: 0 };
  // Ended tasks whose context waits for a started program (9c).
  const lingering = new Set();
  let lastId = 0;

  const nextId = () => {
    // Ids are not 0 (the host) and fit in a u32 below 0xFFFFFFFF (the JS slot owner).
    do lastId = lastId >= 0xfffffffe ? 1 : lastId + 1;
    while (tasks.has(lastId));
    return lastId;
  };

  // A cancel ends a waiting task at once, and a running task at its next wait.
  // `quiet`: no log line. A replace cancels all tasks of the old instance and writes its own line.
  const cancel = (t, reason, quiet = false) => {
    if (!t || t.cancelled) return false;
    t.cancelled = true;
    t.reason = reason;
    stats.cancels++;
    stats.byReason[reason] = (stats.byReason[reason] ?? 0) + 1;
    if (!quiet) opts.log?.(`task cancelled (${reason}): task ${t.id}, ${t.kind}, ${t.waiting ? `in a wait for ${now() - t.waitingSince} ms` : 'running'}`);
    if (t.waiting) opts.onCancel?.(t);
    t.wake?.();
    return true;
  };

  // The refs of the task go (RS1), and its signal aborts: a helper that waits on it stops (OP8).
  const freeContext = (t) => {
    if (t.freed) return;
    t.freed = true;
    lingering.delete(t);
    stats.contextsLive--;
    t.refs.clear();
    t.pctx?.ctl.abort(new DOMException('the task ended', 'AbortError'));
  };

  return {
    deadlines: d,
    stats,
    get size() {
      return tasks.size;
    },
    get: (id) => tasks.get(id),
    // The tasks in flight on `inst` (cancelled ones too, until they end).
    count: (inst) => live.get(inst) ?? 0,
    // The number of instances with a task that is not cancelled (M1: never above 1 after 4a).
    liveInstances() {
      const seen = new Set();
      for (const t of tasks.values()) if (!t.cancelled) seen.add(t.inst);
      return seen.size;
    },
    // A new task on `inst`, or null when all `slots` of the instance are in use (a shed).
    // kind: the event kind (API.md 10). signal: `request.signal`, a cancel when it aborts.
    // env, ctx, event: the context of the task, one for each task (9b).
    begin(inst, { kind = 'Fetch', signal, slots = Infinity, env, ctx, event, hooks } = {}) {
      const n = live.get(inst) ?? 0;
      if (n >= slots) {
        stats.shed++;
        return null;
      }
      live.set(inst, n + 1);
      stats.started++;
      const t = {
        id: nextId(), inst, kind, startedAt: now(),
        env, ctx, event, hooks, refs: new Refs(stats), pctx: null, spawns: 0, ended: false, ok: false, endedAt: 0,
        writers: null, responseWriter: undefined,
        waiting: false, waitingSince: 0, socketWait: false,
        response: 'none', completeAt: 0,
        cancelled: false, reason: null, hostFreed: false, ended5: false, wake: null, wakeOwn: null, ownWoken: null, unlisten: null,
      };
      tasks.set(t.id, t);
      stats.contextsLive++;
      if (signal) {
        const onAbort = () => cancel(t, 'signal');
        if (signal.aborted) onAbort();
        else {
          signal.addEventListener('abort', onAbort, { once: true });
          t.unlisten = () => signal.removeEventListener('abort', onAbort);
        }
      }
      return t;
    },
    end(t) {
      if (tasks.get(t.id) !== t) return;
      tasks.delete(t.id);
      t.unlisten?.();
      const n = live.get(t.inst) - 1;
      if (n) live.set(t.inst, n);
      else live.delete(t.inst);
      t.ended = true;
      t.endedAt = now();
      // An open `Body.writer!` stream: closed when the task returned (`ok`), else aborted, so the client sees the end.
      if (t.writers) for (const s of t.writers) s.finish(t.ok && !t.cancelled);
      if (t.spawns === 0) freeContext(t);
      else lingering.add(t);
    },
    // A started program (`pf.spawn`, `Io.start!`) keeps the context of its task until it settles (RS1).
    spawnStart(t) {
      t.spawns++;
    },
    spawnEnd(t) {
      if (--t.spawns === 0 && t.ended) freeContext(t);
    },
    // The wait starts. Returns the cancel promise: it resolves when the task is cancelled. `t.ownWoken` resolves when a
    // sweep of the own context of the task sees it cancelled (`sweep(own)`). workerd can keep a wake from another request
    // context until the context of the task has I/O (a Durable Object), so the wait races both.
    waitStart(t, socket = false) {
      t.waiting = true;
      t.waitingSince = now();
      t.socketWait = socket;
      t.ownWoken = new Promise((r) => (t.wakeOwn = r));
      return new Promise((r) => (t.wake = r));
    },
    waitStop(t) {
      t.waiting = false;
      t.socketWait = false;
      t.wake = null;
      t.wakeOwn = null;
      t.ownWoken = null;
    },
    // Response state (8b): the early response with a body that is complete now, or open (a writer, a 101).
    respond(t, open = false) {
      t.response = open ? 'open' : 'complete';
      if (!open) t.completeAt = now();
    },
    // A Body.writer! stream closed, or the socket of a 101 closed.
    bodyComplete(t) {
      t.response = 'complete';
      t.completeAt = now();
    },
    cancel,
    // Cancel each task past its deadline. Each new request calls it first (PLAN.md 3b). Also free the context of an
    // ended task past the `waitUntil` limit (9c): its started programs see the abort of their signal.
    // `own`: the `hooks` of the task of the caller's request context. That task, when cancelled (also before, from
    // another context), is woken again from here (`wakeOwn`).
    sweep(own) {
      const at = now();
      let n = 0;
      for (const t of tasks.values()) {
        if (!t.cancelled && at >= deadlineOf(t, d) && cancel(t, 'deadline')) n++;
        if (own && t.hooks === own && t.cancelled) t.wakeOwn?.();
      }
      for (const t of lingering) {
        if (at < lingerUntil(t, d)) continue;
        stats.contextsExpired++;
        opts.log?.(`task context freed at the waitUntil limit: task ${t.id}, ${t.kind}, ${t.spawns} started programs still run`);
        freeContext(t);
      }
      return n;
    },
    // The ended tasks whose context waits for a started program.
    get lingering() {
      return lingering.size;
    },
    // A replace (M1): cancel all tasks of the old instance, so it can be collected.
    cancelAll(inst, reason = 'replace') {
      let n = 0;
      for (const t of tasks.values()) if (t.inst === inst && cancel(t, reason, true)) n++;
      return n;
    },
  };
}
