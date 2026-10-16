// Runtime of the bench app, shared by the worker and the Node test.
// Variant "a": a new instance for each request. Variant "b": one shared
// instance, the host copies the shadow stack at each wait.
import { makeTaskTable } from './tasks.js';

const dec = new TextDecoder();
const enc = new TextEncoder();

// The wait import (kinds as app/app.roc). It reads the arguments before its
// first await: in variant B they can be on the stack that others now use.
// One try/catch covers all code after that. It always returns a status and never
// rejects: a throw into the waiting task would skip `waitEnd` and lose the task.
// Status: 200 ok, 0 no result (io or a JS error), 4 `js_alloc` is out of memory,
// 5 cancelled (PLAN.md 3c). `id`: the task (the host gives it). `tasks`: the task table.
export function makeWait(cell, io, tasks) {
  return async (kind, num, ap, al, bp, bl, cp, cl, out, id) => {
    const x = cell.x;
    const t = tasks?.get(id);
    // A task that was cancelled while it ran ends at its next wait.
    if (t?.cancelled) return end5(x, t);
    const u8 = new Uint8Array(x.memory.buffer);
    const a = dec.decode(u8.subarray(ap, ap + al));
    const b = dec.decode(u8.subarray(bp, bp + bl));
    let p = 0;
    try {
      let v;
      if (t) {
        // A cancel wins the race, so the suspended stack always ends (3.0: it is never freed).
        const cancelled = tasks.waitStart(t);
        try {
          v = await Promise.race([io(kind, a, b), cancelled]);
        } finally {
          tasks.waitStop(t);
        }
        if (t.cancelled) return end5(x, t);
      } else v = await io(kind, a, b);
      const body = enc.encode(v);
      if (body.length) {
        p = x.js_alloc(body.length);
        if (!p) return 4;
        new Uint8Array(x.memory.buffer).set(body, p);
      }
      const dv = new DataView(x.memory.buffer);
      dv.setUint32(out, p, true);
      dv.setUint32(out + 4, body.length, true);
      return 200;
    } catch {
      // The block is not in `out`, so nobody else frees it.
      try {
        if (p) x.res_free(p);
      } catch {}
      if (t?.cancelled) return end5(x, t);
      return 0;
    }
  };
}

// The host frees the wait record and pages of cancelled task `t`, once: at the cancel when
// it waits, else at its next wait.
function hostCancel(x, t) {
  if (t.hostFreed) return;
  t.hostFreed = true;
  try {
    x.task_cancel(t.id);
  } catch {}
}

// End a cancelled task: status 5 makes it trap before it touches memory (3c), because the
// host has freed its record and pages. `ended5` tells the runner that this trap is a cancel.
function end5(x, t) {
  hostCancel(x, t);
  t.ended5 = true;
  return 5;
}

// CPU flags of workerd (PLAN.md problem 5). The exported globals `__instance_signal` and
// `__instance_terminated` hold the address of a u32 in linear memory. workerd writes 24 (SIGXCPU)
// to the signal near the CPU limit, and 1 to the flag of a terminated isolate (`hostlib/cpu.zig`).
// 0 when the module has no such export.
export const SIGXCPU = 24;
export const TERMINATED = 1;
// `trap_cause()` of the host: 1 after a clean trap that the CPU signal made.
const CAUSE_CPU = 1;
export function readFlag(x, name) {
  const g = x[name];
  return g ? new DataView(x.memory.buffer).getUint32(g.value, true) : 0;
}

// A V8 engine stack overflow in the task (4-pre, V1): the stack pointer is not wrapped then.
const isStackError = (e) => e instanceof RangeError && /call stack/i.test(e.message);

function readRes(x, blk) {
  const len = new DataView(x.memory.buffer).getUint32(blk, true);
  const s = dec.decode(new Uint8Array(x.memory.buffer, blk + 4, len));
  x.res_free(blk);
  return s;
}

// Log lines of the host (`dbg`): read them and free them. Call after each `handle` and
// each `task_abort`. The host blocks have owner 0, so a trap does not free them.
function drainLog(x, onLog) {
  const n = x.log_len();
  if (n === 0) return;
  const w = new Uint32Array(x.memory.buffer, x.log_ptr(), n);
  for (let i = 0; i + 2 < n; i += 3) {
    const text = dec.decode(new Uint8Array(x.memory.buffer, w[i], w[i + 1]));
    onLog?.(w[i + 2], text);
  }
  x.log_clear();
}

// The word that marks a free small block: random for each instance, so live
// data matches it only by chance (as the glibc tcache key).
const freeMark = (x) => x.set_free_mark(crypto.getRandomValues(new Uint32Array(1))[0] | 1);

export function instanceA(module, io, tasks) {
  const cell = { x: null };
  const inst = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io, tasks)) } });
  cell.x = inst.exports;
  freeMark(cell.x);
  cell.x.init(0);
  return cell.x;
}

// Shim option `resumeCheck` (PLAN.md 12b) to the sum mode of the host. "always": a sum at each
// wait, a check at each resume after other code ran. "afterAlarm": a check only after an alarm.
// "off": no sums (bench only, 12f).
export const SUM_MODES = { always: 2, afterAlarm: 1, off: 0 };
// `task_abort` gives maxInt (-1 in JS) for an unclean trap, maxInt - cause for an alarm at resume.
const ALARM_OF = { [-1]: 'trap', [-2]: 'sum', [-3]: 'block' };
// Codes of `check_heap()` (PLAN.md 12d, `hostlib/alloc.zig` CHECK_*, `host/host.zig`). -1: the check trapped.
export const CHECK_NAMES = {
  [-1]: 'trap in the check', 1: 'pool bounds', 2: 'free runs', 3: 'free bits', 4: 'page reserve', 5: 'task slots',
  6: 'small page', 7: 'free list of a small page', 8: 'pages with room', 9: 'large block', 10: 'unit in no place or in two',
  11: 'unit or byte counts', 12: 'constant data', 13: 'host globals', 14: 'wait records', 15: 'log',
};
// Shim option `heapCheckEvery` (PLAN.md 12e): the global check after this many requests. The
// smallest round number that keeps the check at or below 0.1 % of the CPU time (`bench/checkcost.mjs`).
export const HEAP_CHECK_EVERY = 1000;

// A shared instance (variant B): the host copies the stack at each wait.
// `slots`: the most tasks in flight on it (PLAN.md 2c).
function instanceB(module, io, tasks, sumMode) {
  const cell = { x: null };
  const inst = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io, tasks)) } });
  const x = (cell.x = inst.exports);
  freeMark(x);
  x.set_sum(sumMode);
  x.init(1);
  return { x, handle: WebAssembly.promising(x.handle), slots: x.task_slots() };
}

// run(req, { kind, signal }) -> { body, x }, or { trap: message, x }. `x`: the instance that ran it.
// A trap result with `status: 503` is a shed (`shed: true`, all task slots in use) or a
// cancel (`cancelled`: the reason, PLAN.md 3b, 3c). kind: the event kind (default 'Fetch').
// signal: `request.signal`; the task is cancelled when it aborts.
// Variant "b" falls back to "a" when the module is not stack-first (`stack_first()`
// is 0): there a stack overflow can write over data, so an instance runs only
// one request. opts.noFallback keeps "b" (only for the overflow test).
// opts: also the deadlines of `tasks.js` (taskDeadlineMs, wallMs, initMs, afterRespondMs),
// `resumeCheck` ("always", the default, or "afterAlarm"; see SUM_MODES), the global check of 12e
// (`heapCheckEvery`, default HEAP_CHECK_EVERY, 0: off; `heapCheckWhenIdle`, default true), and
// `log(text)`: the log lines of the shim (M11; default console.warn).
// ro (of run): also `ctx`: the idle check runs in `ctx.waitUntil` when it is given.
// An alarm (an unclean trap, or a resume check that failed) gives `{ status: 503, alarm: 'trap' | 'sum' | 'block' }`.
export function makeRunner(module, variant, io, opts = {}) {
  const sumMode = SUM_MODES[opts.resumeCheck ?? 'always'];
  if (sumMode === undefined) throw new Error(`resumeCheck: ${opts.resumeCheck}`);
  const stats = {
    served: 0, traps: 0, freed: 0, walkFailed: 0, alarms: 0, byAlarm: {}, retired: 0, terminated: 0, cpu: 0, shed: 0, cancelled: 0, memBytes: 0, maxMemBytes: 0, fallback: false,
    heapChecks: 0, heapCheckMs: 0, heapCheckMaxMs: 0, heapFails: 0, byCheck: {},
  };
  const every = opts.heapCheckEvery ?? HEAP_CHECK_EVERY;
  const whenIdle = opts.heapCheckWhenIdle ?? true;
  const log = opts.log ?? ((text) => console.warn(text));
  // A waiting task is freed in the host at its cancel, so the memory is free at once.
  const tasks = makeTaskTable({ ...opts, onCancel: (t) => hostCancel(t.inst.x, t) });
  const seen = (x) => {
    stats.memBytes = x.memory.buffer.byteLength;
    if (stats.memBytes > stats.maxMemBytes) stats.maxMemBytes = stats.memBytes;
  };
  const cancelled = (t, x) => {
    stats.cancelled++;
    seen(x);
    return { trap: `cancelled: ${t.reason}`, status: 503, cancelled: t.reason, x };
  };
  let cur = variant === 'a' ? null : instanceB(module, io, tasks, sumMode);
  if (cur && !cur.x.stack_first() && !opts.noFallback) {
    console.warn('module is not stack-first: one instance per request');
    stats.fallback = true;
    cur = null;
  }
  if (!cur) {
    return {
      stats,
      tasks,
      x: null,
      async run(req, ro = {}) {
        tasks.sweep();
        const x = instanceA(module, io, tasks);
        const t = tasks.begin({ x }, ro);
        try {
          const arg = enc0(x, req);
          if (!arg) return { trap: 'out of memory: request block', x };
          try {
            const blk = await WebAssembly.promising(x.handle)(...arg, t.id);
            stats.served++;
            seen(x);
            this.x = x;
            const body = readRes(x, blk);
            drainLog(x, opts.onLog);
            return { body, x };
          } catch (e) {
            this.x = x;
            if (t.ended5) return cancelled(t, x);
            stats.traps++;
            seen(x);
            // A new instance for each request: no task_abort, but the log lines are still read.
            try {
              drainLog(x, opts.onLog);
            } catch {}
            // 5b: the CPU signal made a clean trap.
            if (x.trap_cause() === CAUSE_CPU) {
              stats.cpu++;
              return { trap: 'cpu limit', status: 503, cause: 'cpu', x };
            }
            return { trap: String(e), x };
          }
        } finally {
          tasks.end(t);
        }
      },
    };
  }
  // Each instance counts the requests since its last global check, and `dirty`: a task started since then.
  const fresh = (it) => Object.assign(it, { sinceCheck: 0, dirty: false, idlePending: false });
  fresh(cur);
  const runner = {
    stats,
    tasks,
    x: cur.x,
    // M1: a new instance. All tasks of the old one are cancelled (3c), so it can be collected.
    replace(reason = 'replace') {
      const old = cur;
      cur = fresh(instanceB(module, io, tasks, sumMode));
      runner.x = cur.x;
      stats.retired++;
      tasks.cancelAll(old, reason);
    },
    // The global check (PLAN.md 12d) on instance `it` (default: the current one), when no task is in
    // wasm. `why`: 'alarm', 'idle', 'every' (or a test name). Each check adds its time to the counters. A failed check (or a trap in it)
    // writes one log line and replaces the instance (M1: cancel all tasks, drop, new instance).
    // Returns true when the instance stays.
    checkHeap(why, it = cur) {
      if (cur !== it) return false;
      const t0 = performance.now();
      let code;
      try {
        code = it.x.check_heap();
      } catch {
        code = -1;
      }
      const ms = performance.now() - t0;
      stats.heapChecks++;
      stats.heapCheckMs += ms;
      if (ms > stats.heapCheckMaxMs) stats.heapCheckMaxMs = ms;
      stats.byCheck[why] = (stats.byCheck[why] ?? 0) + 1;
      it.sinceCheck = 0;
      it.dirty = false;
      if (code === 0) return true;
      stats.heapFails++;
      log(`heap check failed (${why}): ${code} ${CHECK_NAMES[code] ?? ''}; new instance, ${tasks.count(it)} tasks cancelled`);
      runner.replace('heap');
      return false;
    },
    // 12e: when instance `it` is idle (no task in flight) after a task ran, one global check. It runs
    // after the response (a timer, in `ctx.waitUntil` when there is a ctx), and only when the
    // instance is still current and still idle then.
    idle(it, ctx) {
      if (!whenIdle || cur !== it || !it.dirty || it.idlePending || tasks.count(it) !== 0) return;
      it.idlePending = true;
      const p = new Promise((done) =>
        setTimeout(() => {
          it.idlePending = false;
          if (cur === it && it.dirty && tasks.count(it) === 0) runner.checkHeap('idle', it);
          done();
        }, 0),
      );
      ctx?.waitUntil?.(p);
    },
    // The alarm (PLAN.md 12, "What happens at a resume and after an alarm"): the one path for an
    // unclean trap, a resume check that failed, and a trap in an export after the task (12c). The
    // task gets a 503, and the host has freed its pages and slot (`task_abort`). Then the global
    // check runs at once (no task is in wasm now): the instance stays when it passes. The tasks
    // that resume on it later check their sums ("afterAlarm" too: `set_suspect`).
    alarm(it, t, x, cause, e) {
      stats.alarms++;
      stats.byAlarm[cause] = (stats.byAlarm[cause] ?? 0) + 1;
      if (cause === 'trap') stats.walkFailed++;
      log(`alarm ${cause}: task ${t.id}${e ? `: ${String(e).slice(0, 80)}` : ''}`);
      try {
        x.set_suspect(1);
      } catch {}
      tasks.end(t);
      stats.traps++;
      seen(x);
      runner.checkHeap('alarm', it);
      return { trap: cause === 'trap' ? String(e) : `alarm: ${cause}`, status: 503, alarm: cause, x };
    },
    async run(req, ro = {}) {
      // 5c: workerd stopped the isolate for the CPU limit. No catch ran, so the state of this
      // instance (task top, stack pointer, owner) is stale: M1, a new instance.
      if (readFlag(cur.x, '__instance_terminated') === TERMINATED) {
        stats.terminated++;
        runner.replace('terminated');
      }
      // 3b: a new request runs in a live request context, so it cancels the tasks past their deadline.
      tasks.sweep();
      // 12e: after `heapCheckEvery` requests, the global check before the next task enters wasm.
      if (every > 0 && cur.sinceCheck >= every) runner.checkHeap('every');
      const it = cur;
      const x = it.x;
      // 2c: the host has `slots` task slots. Above that, a shed (M7 step 2): the instance stays.
      const t = tasks.begin(it, { kind: ro.kind, signal: ro.signal, slots: it.slots });
      if (!t) {
        stats.shed++;
        return { trap: 'shed: all task slots are in use', status: 503, shed: true, x };
      }
      it.sinceCheck++;
      it.dirty = true;
      try {
        // js_alloc gave 0: no task started, nothing to abort. A trap in it: a damaged instance (12c).
        let arg;
        try {
          arg = enc0(x, req);
        } catch (e) {
          return runner.alarm(it, t, x, 'trap', e);
        }
        if (!arg) return { trap: 'out of memory: request block', x };
        try {
          const blk = await it.handle(...arg, t.id);
          stats.served++;
          seen(x);
          // 12c: a trap here (a damaged instance) is an alarm too: `run` never throws.
          let body;
          try {
            body = readRes(x, blk);
            drainLog(x, opts.onLog);
          } catch (e) {
            return runner.alarm(it, t, x, 'trap', e);
          }
          return { body, x };
        } catch (e) {
          // A cancel (status 5): the host freed the task at `task_cancel`. Not an alarm.
          if (t.ended5) return cancelled(t, x);
          // A trap in the task: the host gives the stack back and frees the spans
          // of the task. Below 0: the trap was not clean, or a resume check failed: an alarm.
          // A trap in `task_abort` (a damaged instance) is an unclean trap too.
          let freed = -1;
          try {
            freed = x.task_abort(t.id, isStackError(e) ? 1 : 0);
          } catch {}
          const cause = ALARM_OF[freed];
          if (cause) return runner.alarm(it, t, x, cause, e);
          stats.freed += freed;
          try {
            drainLog(x, opts.onLog);
          } catch (e2) {
            return runner.alarm(it, t, x, 'trap', e2);
          }
          stats.traps++;
          seen(x);
          // 5b: a clean trap from the CPU signal. The instance stays. The cause is set only by a clean trap.
          if (x.trap_cause() === CAUSE_CPU) {
            stats.cpu++;
            return { trap: 'cpu limit', status: 503, cause: 'cpu', x };
          }
          return { trap: String(e), x };
        }
      } finally {
        tasks.end(t);
        runner.idle(it, ro.ctx);
      }
    },
  };
  return runner;
}

// The request string in a js_alloc block: [ptr, len] for `handle`. null: out of memory.
function enc0(x, req) {
  const bytes = enc.encode(req);
  const p = x.js_alloc(bytes.length);
  if (!p) return null;
  new Uint8Array(x.memory.buffer).set(bytes, p);
  return [p, bytes.length];
}

// The body the app must give for request `id` at recursion `depth`.
export function expected(id, depth = 50) {
  let sum = 0;
  for (let n = 1; n <= depth; n++) sum += n * 1000 + `level-${n}-of-request-${id}`.length + 1;
  return { sum, prefix: `id=${id} `, suffix: ` sum=${sum} fetch=f:${id} db=d:${id}` };
}

export function check(id, body, depth = 50) {
  const e = expected(id, depth);
  return body.startsWith(e.prefix) && body.endsWith(e.suffix);
}
