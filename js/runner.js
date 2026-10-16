// The runner: instances, the tasks that run on them, and the alarm and check paths (PLAN.md 1 to 5, 12).
// One shared instance: the host copies the shadow stack at each wait.
import { makeTaskTable } from './tasks.js';
import { makeBudget } from './budget.js';
import { hostCancel } from './wait.js';
import { makeBridge } from './bridge.js';
import { makePins } from './helpers.js';
import { Refs } from './values.js';
import { SUM_MODES, ALARM_OF, CHECK_NAMES, CHECK_BUSY, CAUSE_CPU, CAUSE_OOM, HEAP_CHECK_EVERY, TERMINATED, LOG_CRASH, readFlag, readOutcome, drainLog, hostCounters, freeMark, isStackError, encEvent, eventBytes } from './host.js';

// The error for a module that is not stack-first (PLAN.md 1b): the platform has no fallback.
export const NOT_STACK_FIRST =
  'the module is not stack-first: its shadow stack lies above its data (stack_first() is 0), so a stack overflow can write over data. ' +
  'The platform needs a stack-first build and has no fallback. Build with a Roc nightly that puts the stack first ' +
  '(compat/last-stack-first-nightly) and check the file with bench/check-layout.mjs.';

// The imports of an instance. `js_grow(pages)` (PLAN.md M4): 1 when the budget allows the grow, else 0.
// No budget: always 1.
// `js_await` and `js_call` (API.md 4.1): the bridge. `shim`: `{ ops, pins, log }` of the runner (API.md 6.4, RS2).
function importsOf(cell, tasks, budget, shim = SHIM0) {
  const bridge = makeBridge(cell, tasks, shim);
  return {
    env: {
      js_await: new WebAssembly.Suspending(bridge.js_await),
      js_call: bridge.js_call,
      js_grow: (pages) => (budget ? budget.ask(cell.x.memory, pages) : 1),
    },
  };
}
// The shim of an instance that no runner made (tests).
const SHIM0 = { ops: {}, pins: makePins(), log: (text) => console.warn(text), crossings: { await: 0, call: 0 } };

// A new instance counts in the budget at once, and its grow step is the shim option.
function register(x, budget) {
  budget?.add(x.memory);
  if (budget) x.set_grow_step(budget.options.growStepBytes);
}

// A shared instance: the host copies the stack at each wait.
// `slots`: the most tasks in flight on it (PLAN.md 2c).
function instanceB(module, tasks, sumMode, budget, shim) {
  const cell = { x: null, cancelTrap: null };
  const inst = new WebAssembly.Instance(module, importsOf(cell, tasks, budget, shim));
  const x = (cell.x = inst.exports);
  register(x, budget);
  freeMark(x);
  // PLAN.md 7a: the production host refuses mode 0 (no sums): it returns 0 and keeps mode 2.
  if (!x.set_sum(sumMode)) throw new Error('resumeCheck "off" needs the bench host: the production host refuses it');
  x.init(1);
  return { x, cell, handle: WebAssembly.promising(x.handle), slots: x.task_slots() };
}

// run(event, { kind, signal }) -> { outcome, x }, or { trap: message, x }. `event`: the JS value of an event
// (`js/events.js`, API.md 10.1), `outcome`: the outcome of the app as a JS value (`platform/Entry.roc`). A clean trap
// after a Roc `crash` has its text in `crash`. `x`: the instance that ran it.
// A trap result with `status: 503` is a shed (`shed: true`, all task slots in use) or a
// cancel (`cancelled`: the reason, PLAN.md 3b, 3c). kind: the event kind (default 'Fetch').
// signal: `request.signal`; the task is cancelled when it aborts.
// A module that is not stack-first (`stack_first()` is 0) is refused with an error at the first instance:
// there a stack overflow can write over data, and the platform has no fallback (PLAN.md 1b).
// opts: also the deadlines of `tasks.js` (taskDeadlineMs, wallMs, initMs, afterRespondMs),
// `resumeCheck` ("always", the default, or "afterAlarm"; see SUM_MODES), the global check of 12e
// (`heapCheckEvery`, default HEAP_CHECK_EVERY, 0: off; `heapCheckWhenIdle`, default true), and
// `log(text)`: the log lines of the shim (M11; default console.warn), and the memory options of
// `budget.js` (isolateBytes, jsReserveBytes, maxInstanceBytes, growStepBytes, graceMs).
// ro (of run): also `hooks` (`js/tasks.js`: what the entry gives to the platform helpers), `ctx`: the idle check runs in `ctx.waitUntil` when it is given. `env`, `ctx`, `event` (the request)
// are the context of the task (PLAN.md 9b): the task table keeps them, and a program gets them as its roots (API.md 6.2, OP3).
// opts.ops: the JS functions of the app (the root `ops`), opts.pinLimit: the size of the pin table (API.md 6.4, RS2).
// An alarm (an unclean trap, or a resume check that failed) gives `{ status: 503, alarm: 'trap' | 'sum' | 'block' }`.
// Memory (PLAN.md 4b to 4e): a task that a denied grow stopped gives `{ status: 503, cause: 'oom' }`. A request that
// memory pressure refuses gives `{ status: 503, shed: true, reason }` (M7 step 2).
export function makeRunner(module, opts = {}) {
  const sumMode = SUM_MODES[opts.resumeCheck ?? 'always'];
  if (sumMode === undefined) throw new Error(`resumeCheck: ${opts.resumeCheck}`);
  const stats = {
    served: 0, traps: 0, freed: 0, walkFailed: 0, alarms: 0, byAlarm: {}, retired: 0, terminated: 0, cpu: 0, shed: 0, cancelled: 0, memBytes: 0, maxMemBytes: 0, oom: 0, shedMem: 0, replaces: {},
    heapChecks: 0, heapCheckMs: 0, heapCheckMaxMs: 0, heapFails: 0, heapBusy: 0, byCheck: {},
    doubleFrees: 0, deallocMiss: 0, idleResets: 0, idleResetsSkipped: 0, idleResetBytes: 0,
  };
  const every = opts.heapCheckEvery ?? HEAP_CHECK_EVERY;
  const whenIdle = opts.heapCheckWhenIdle ?? true;
  const log = opts.log ?? ((text) => console.warn(text));
  // M3: the budget of the isolate. JS asks it at each grow (`js_grow`) and counts dropped instances (M10).
  const budget = makeBudget({ ...opts, log });
  stats.budget = budget.stats;
  // A waiting task is freed in the host at its cancel, so the memory is free at once.
  // M11: a cancel writes one line (`tasks.js`). A trap in `task_cancel` is an alarm (12c, `cancelTrap`).
  const cancelTrap = (x, t, e) => {
    runner?.raise(t.inst, x, 'cancel', t, e);
    if (runner) runner.due(t.inst);
    else {
      stats.alarms++;
      stats.byAlarm.cancel = (stats.byAlarm.cancel ?? 0) + 1;
      log(`alarm cancel: task ${t.id}: ${String(e).slice(0, 80)}`);
    }
  };
  const tasks = makeTaskTable({ ...opts, log, onCancel: (t) => hostCancel(t.inst.x, t, cancelTrap) });
  // API.md 6.4: the JS functions of the app (root `ops`), the pin table of the isolate (RS2, `pinLimit`).
  // `crossings`: the calls of `js_await` and `js_call` of all instances (PLAN.md 8c: "one crossing" tests).
  const shim = { ops: opts.ops ?? {}, pins: makePins(opts.pinLimit ?? 1000, opts.now), log, crossings: { await: 0, call: 0 } };
  stats.pins = shim.pins.stats;
  stats.crossings = shim.crossings;
  const seen = (x) => {
    stats.memBytes = x.memory.buffer.byteLength;
    if (stats.memBytes > stats.maxMemBytes) stats.maxMemBytes = stats.memBytes;
  };
  const cancelled = (t, x) => {
    stats.cancelled++;
    seen(x);
    return { trap: `cancelled: ${t.reason}`, status: 503, cancelled: t.reason, x };
  };
  // M11: the host counts a caught double free and a refused free (`double_frees`, `dealloc_miss`). JS writes
  // one line when one goes up, after each task and each global check. The counts of each instance are separate.
  const evSeen = new WeakMap();
  const hostEvents = (x) => {
    let e = evSeen.get(x);
    if (!e) evSeen.set(x, (e = { df: 0, dm: 0 }));
    let df, dm;
    try {
      df = x.double_frees();
      dm = x.dealloc_miss();
    } catch {
      return;
    }
    if (df !== e.df) {
      stats.doubleFrees += df - e.df;
      log(`double free caught: ${df - e.df} new, ${df} in this instance (the second free was not done)`);
      e.df = df;
    }
    if (dm !== e.dm) {
      stats.deallocMiss += dm - e.dm;
      log(`free refused: ${dm - e.dm} new, ${dm} in this instance (a free or realloc of a block of another task)`);
      e.dm = dm;
    }
  };
  let cur = instanceB(module, tasks, sumMode, budget, shim);
  let runner;
  if (!cur.x.stack_first()) throw new Error(NOT_STACK_FIRST);
  // The result of a clean trap: the host says why (the CPU signal, 5b, or out of memory, M6).
  // `crash`: the text of a Roc `crash` from the log of the host (8a O2), or undefined.
  const cleanTrap = (x, e, crash) => {
    const cause = x.trap_cause();
    if (cause === CAUSE_CPU) {
      stats.cpu++;
      return { trap: 'cpu limit', status: 503, cause: 'cpu', x };
    }
    if (cause === CAUSE_OOM) {
      stats.oom++;
      return { trap: 'out of memory', status: 503, cause: 'oom', x };
    }
    return crash === undefined ? { trap: String(e), x } : { trap: String(e), crash, x };
  };
  // Read and free the log lines of the host. Gives the text of the last crash line, or undefined.
  const drain = (x) => {
    let crash;
    drainLog(x, (level, text) => {
      if (level === LOG_CRASH) crash = text;
      opts.onLog?.(level, text);
    });
    return crash;
  };
  // The event as CBOR, before the task enters wasm. A value that cannot cross (J1, J3): a 500, no task in wasm.
  const encode = (ev, t, x) => {
    try {
      return { bytes: eventBytes(ev, t.refs) };
    } catch (e) {
      return { fail: { trap: `the event cannot cross: ${e.message}`, status: 500, x } };
    }
  };
  // A request that memory pressure refuses (M7 step 2): a 503, one log line.
  const shedMem = (reason, x) => {
    stats.shedMem++;
    log(`request shed: ${reason}`);
    return { trap: `shed: ${reason}`, status: 503, shed: true, reason, x };
  };
  // Each instance counts the requests since its last global check, and `dirty`: a task started since
  // then. `checkDue`: an alarm happened, and the check did not run yet (12c).
  const fresh = (it) => {
    it.cell.gate = () => runner.gate(it);
    it.cell.cancelTrap = cancelTrap;
    return Object.assign(it, { sinceCheck: 0, dirty: false, idlePending: false, checkDue: false });
  };
  runner = {
    stats,
    tasks,
    budget,
    x: cur.x,
    // The counters of the host for the current instance.
    counters() {
      return hostCounters(cur.x);
    },
    // M1: a new instance. All tasks of the old one are cancelled (3c), so it can be collected. The
    // old one counts in the budget until it is collected (M10). One log line, unless the caller
    // (a failed check) wrote it (`logged`).
    replace(reason = 'replace', logged = false) {
      const old = cur;
      cur = fresh(instanceB(module, tasks, sumMode, budget, shim));
      runner.x = cur.x;
      stats.retired++;
      stats.replaces[reason] = (stats.replaces[reason] ?? 0) + 1;
      const n = tasks.cancelAll(old, reason);
      budget.drop(old.x.memory);
      if (!logged) log(`replace (${reason}): ${n} tasks cancelled, new instance, ${(budget.droppedBytes / 2 ** 20).toFixed(1)} MB of dropped instances not collected`);
    },
    // The global check (PLAN.md 12d) on instance `it` (default: the current one), when no task is in
    // wasm. `why`: 'alarm', 'idle', 'every' (or a test name). Each check adds its time to the counters.
    // A failed check (or a trap in it) writes one log line and replaces the instance (M1: cancel all
    // tasks, drop, new instance). `inJob`: JS calls it from a promise job, so the catch of a task that
    // trapped can still be in the queue: the host answers CHECK_BUSY, and the check stays due (at a
    // timer, CHECK_BUSY is a failure). Returns true when the instance stays.
    checkHeap(why, it = cur, inJob = false) {
      if (cur !== it) return false;
      hostEvents(it.x);
      const t0 = performance.now();
      let code;
      try {
        code = it.x.check_heap();
      } catch {
        code = -1;
      }
      const ms = performance.now() - t0;
      if (code === CHECK_BUSY && inJob) {
        stats.heapBusy++;
        return true;
      }
      stats.heapChecks++;
      stats.heapCheckMs += ms;
      if (ms > stats.heapCheckMaxMs) stats.heapCheckMaxMs = ms;
      stats.byCheck[why] = (stats.byCheck[why] ?? 0) + 1;
      it.sinceCheck = 0;
      it.dirty = false;
      it.checkDue = false;
      if (code === 0) return true;
      stats.heapFails++;
      log(`heap check failed (${why}): ${code} ${CHECK_NAMES[code] ?? ''}; new instance, ${tasks.count(it)} tasks cancelled`);
      runner.replace('heap', true);
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
          if (cur === it && it.dirty && tasks.count(it) === 0 && runner.checkHeap('idle', it)) runner.idleDone(it);
          done();
        }, 0),
      );
      ctx?.waitUntil?.(p);
    },
    // A passed idle check: no task waits, and the heap is sound. So the suspicion of an alarm ends (12c: a
    // resume checks its sum only after an alarm, `set_suspect`), and the heap starts again when no block is
    // live (PLAN.md H2, 4j: `idle_reset`). The host refuses the reset when a task runs or waits, or a block is live.
    idleDone(it) {
      const x = it.x;
      try {
        x.set_suspect(0);
        const before = x.heap_used();
        if (x.idle_reset()) {
          stats.idleResets++;
          stats.idleResetBytes += before - x.heap_used();
        } else stats.idleResetsSkipped++;
      } catch {}
    },
    // 12c: the check after an alarm, when it is due: before the next `handle` (`run`) and before
    // the next resume (`js_await`). `inJob`: see `checkHeap`.
    gate(it, inJob = true) {
      if (it.checkDue && cur === it) runner.checkHeap('alarm', it, inJob);
    },
    // The alarm (PLAN.md 12, "What happens at a resume and after an alarm"): the one path for an
    // unclean trap, a resume check that failed, and a trap in an export after the task (12c). The
    // task gets a 503, and the host has freed its pages and slot (`task_abort`). Then the global
    // check runs (no task is in wasm now), at once or at the next gate, and at the latest at a
    // timer: the instance stays when it passes. The tasks that resume on it later check their
    // sums ("afterAlarm" too: `set_suspect`).
    alarm(it, t, x, cause, e) {
      runner.raise(it, x, cause, t, e);
      tasks.end(t);
      stats.traps++;
      seen(x);
      runner.due(it);
      return { trap: cause === 'trap' ? String(e) : `alarm: ${cause}`, status: 503, alarm: cause, x };
    },
    // The count, the log line and the suspicion of an alarm (M11). `t`: the task of the alarm. The cause
    // 'cancel' is a trap in `task_cancel` (a damaged instance): the task is cancelled in any case.
    raise(it, x, cause, t, e) {
      stats.alarms++;
      stats.byAlarm[cause] = (stats.byAlarm[cause] ?? 0) + 1;
      if (cause === 'trap') stats.walkFailed++;
      log(`alarm ${cause}: task ${t.id}${e ? `: ${String(e).slice(0, 80)}` : ''}`);
      try {
        x.set_suspect(1);
      } catch {}
    },
    // The global check is due: at once, else at the next gate, and at the latest at a timer.
    due(it) {
      it.checkDue = true;
      runner.gate(it);
      if (it.checkDue) setTimeout(() => runner.gate(it, false), 0);
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
      // M7 step 2: a grow was denied in the last `graceMs`, or the new instance of a replace does not fit
      // next to the old one (M1). Requests in flight go on.
      if (budget.pressure()) return shedMem('a grow was denied in the last graceMs', cur.x);
      if (budget.crowded()) return shedMem('the old instance is not collected (M1)', cur.x);
      // 12e: after `heapCheckEvery` requests, the global check before the next task enters wasm.
      // 12c: a check that an alarm made due runs before this task enters wasm.
      runner.gate(cur);
      if (every > 0 && cur.sinceCheck >= every) runner.checkHeap('every', cur, true);
      const it = cur;
      const x = it.x;
      // 2c: the host has `slots` task slots. Above that, a shed (M7 step 2): the instance stays.
      const t = tasks.begin(it, { kind: ro.kind, signal: ro.signal, slots: it.slots, env: ro.env, ctx: ro.ctx, event: ro.event, hooks: ro.hooks });
      if (!t) {
        stats.shed++;
        return { trap: 'shed: all task slots are in use', status: 503, shed: true, x };
      }
      it.sinceCheck++;
      it.dirty = true;
      try {
        // js_alloc gave 0: no task started, nothing to abort. A trap in it: a damaged instance (12c).
        const ev = encode(req, t, x);
        if (ev.fail) return ev.fail;
        let arg;
        try {
          arg = encEvent(x, ev.bytes);
        } catch (e) {
          return runner.alarm(it, t, x, 'trap', e);
        }
        if (!arg) {
          stats.oom++;
          return { trap: 'out of memory: request block', status: 503, cause: 'oom', x };
        }
        try {
          const blk = await it.handle(...arg, t.id);
          t.ok = true;
          stats.served++;
          seen(x);
          // 12c: a trap here (a damaged instance) is an alarm too: `run` never throws.
          let outcome;
          try {
            outcome = readOutcome(x, blk, t.refs);
            drain(x);
          } catch (e) {
            return runner.alarm(it, t, x, 'trap', e);
          }
          return { outcome, x };
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
          let crash;
          try {
            crash = drain(x);
          } catch (e2) {
            return runner.alarm(it, t, x, 'trap', e2);
          }
          stats.traps++;
          seen(x);
          // 5b, M6: the host says why a clean trap happened (the CPU signal, out of memory). The instance stays.
          return cleanTrap(x, e, crash);
        }
      } finally {
        tasks.end(t);
        hostEvents(x);
        runner.idle(it, ro.ctx);
      }
    },
  };
  fresh(cur);
  return runner;
}

// The event `Manifest` (API.md 10.1, AQ10) at load: the names of the classes and methods of the app, as a JS value
// (`{ default, objects, entrypoints }`), or null when the app answers `Unhandled` (no `Worker` wrapper: no classes).
// It runs on an instance of its own, made and dropped here, with no task table and no budget: `makeHandler` runs at
// global scope, where workerd forbids random values (the free mark of a runner instance, C3 of PLAN.md 8b). The event
// makes no crossing, so `handle` runs as a plain call (no JSPI). A crash of the app or an outcome of another kind is a
// throw, so the load fails with the text. A module that is not stack-first is not run: the result is `undefined`, and
// its first event throws (PLAN.md 1b).
export function manifestOf(module, ev) {
  const none = () => 3; // status 3: the Manifest event has no program
  const x = new WebAssembly.Instance(module, { env: { js_await: new WebAssembly.Suspending(async () => 3), js_call: none, js_grow: () => 1 } }).exports;
  x.init(1);
  if (!x.stack_first()) return undefined;
  const refs = new Refs();
  const arg = encEvent(x, eventBytes(ev, refs));
  if (!arg) throw new Error('manifest: no memory for the event');
  let crash;
  let blk;
  try {
    blk = x.handle(...arg, 1);
  } catch (e) {
    drainLog(x, (level, text) => {
      if (level === LOG_CRASH) crash = text;
    });
    throw new Error(`manifest: the app trapped: ${crash ?? e}`);
  }
  const o = readOutcome(x, blk, refs);
  if (o.outcome === 'unhandled') return null;
  if (o.outcome !== 'reply') throw new Error(`manifest: the outcome ${o.outcome} is not Reply`);
  return o.value;
}
