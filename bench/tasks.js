// Task table of the JS shim (PLAN.md 3a, 3b, 3c). One entry for each task in flight.
// It knows no wasm: the runner (`core.js`) starts and ends tasks, and the import wrapper
// (`makeWait`) marks each wait and ends a cancelled task with status 5.
// 8a and 9a reuse it: 9b adds the context of a task (env, ctx, event, refs) to the entry.

// Deadlines of API.md 10.2. Shim options: a test can make them smaller.
export const DEADLINES = {
  taskDeadlineMs: 120_000, // each wait of a Fetch task before respond!, and of a kind with no limit
  wallMs: 15 * 60_000, // the whole task: Scheduled, Queue, Alarm
  initMs: 30_000, // the whole task: Init of an object
  afterRespondMs: 30_000, // after the response body is complete (the waitUntil limit)
};

// Kinds with a wall time limit for the whole task, and no deadline for one wait.
const WALL = new Set(['Scheduled', 'Queue', 'Alarm']);

// The time at which task `t` must be cancelled, or Infinity (API.md 10.2). Pure.
// response: 'none' (no respond! yet), 'open' (respond! with a Body.writer! stream that
// is not closed, or a 101 with an open socket), 'complete' (at `completeAt`).
export function deadlineOf(t, d = DEADLINES) {
  if (t.waiting && t.socketWait) return Infinity;
  if (t.response === 'complete') return t.completeAt + d.afterRespondMs;
  if (t.response === 'open') return Infinity;
  if (WALL.has(t.kind)) return t.startedAt + d.wallMs;
  if (t.kind === 'Init') return t.startedAt + d.initMs;
  return t.waiting ? t.waitingSince + d.taskDeadlineMs : Infinity;
}

// opts: the DEADLINES keys, `now` (a clock for tests), `onCancel(t)`: called at the cancel
// of a task that waits (the runner frees it in the host there, PLAN.md 3c).
export function makeTaskTable(opts = {}) {
  const d = { ...DEADLINES };
  for (const k of Object.keys(DEADLINES)) if (opts[k] !== undefined) d[k] = opts[k];
  const now = opts.now ?? (() => Date.now());
  const tasks = new Map();
  const live = new Map(); // instance -> tasks in flight
  const stats = { started: 0, shed: 0, cancels: 0, byReason: {} };
  let lastId = 0;

  const nextId = () => {
    // Ids are not 0 (the host) and fit in a u32 below 0xFFFFFFFF (the JS slot owner).
    do lastId = lastId >= 0xfffffffe ? 1 : lastId + 1;
    while (tasks.has(lastId));
    return lastId;
  };

  // A cancel ends a waiting task at once, and a running task at its next wait.
  const cancel = (t, reason) => {
    if (!t || t.cancelled) return false;
    t.cancelled = true;
    t.reason = reason;
    stats.cancels++;
    stats.byReason[reason] = (stats.byReason[reason] ?? 0) + 1;
    if (t.waiting) opts.onCancel?.(t);
    t.wake?.();
    return true;
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
    begin(inst, { kind = 'Fetch', signal, slots = Infinity } = {}) {
      const n = live.get(inst) ?? 0;
      if (n >= slots) {
        stats.shed++;
        return null;
      }
      live.set(inst, n + 1);
      stats.started++;
      const t = {
        id: nextId(), inst, kind, startedAt: now(),
        waiting: false, waitingSince: 0, socketWait: false,
        response: 'none', completeAt: 0,
        cancelled: false, reason: null, hostFreed: false, ended5: false, wake: null, unlisten: null,
      };
      tasks.set(t.id, t);
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
    },
    // The wait starts. Returns the cancel promise: it resolves when the task is cancelled.
    waitStart(t, socket = false) {
      t.waiting = true;
      t.waitingSince = now();
      t.socketWait = socket;
      return new Promise((r) => (t.wake = r));
    },
    waitStop(t) {
      t.waiting = false;
      t.socketWait = false;
      t.wake = null;
    },
    // Response state (8b): respond! with a body that is complete now, or open (a writer, a 101).
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
    // Cancel each task past its deadline. Each new request calls it first (PLAN.md 3b).
    sweep() {
      const at = now();
      let n = 0;
      for (const t of tasks.values()) if (!t.cancelled && at >= deadlineOf(t, d) && cancel(t, 'deadline')) n++;
      return n;
    },
    // A replace (M1): cancel all tasks of the old instance, so it can be collected.
    cancelAll(inst, reason = 'replace') {
      let n = 0;
      for (const t of tasks.values()) if (t.inst === inst && cancel(t, reason)) n++;
      return n;
    },
  };
}
