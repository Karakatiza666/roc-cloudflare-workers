// Readers and constants of the host exports (the wasm side of the shim). It knows no task and no budget.
import { toJs, fromJs } from './values.js';

export const dec = new TextDecoder();
export const enc = new TextEncoder();

// CPU flags of workerd (PLAN.md problem 5). The exported globals `__instance_signal` and
// `__instance_terminated` hold the address of a u32 in linear memory. workerd writes 24 (SIGXCPU)
// to the signal near the CPU limit, and 1 to the flag of a terminated isolate (`hostlib/cpu.zig`).
// 0 when the module has no such export.
export const SIGXCPU = 24;
export const TERMINATED = 1;
// `trap_cause()` of the host: 1 after a clean trap that the CPU signal made, 2 after one that
// out of memory made (a denied grow, M6).
export const CAUSE_CPU = 1;
export const CAUSE_OOM = 2;
export function readFlag(x, name) {
  const g = x[name];
  return g ? new DataView(x.memory.buffer).getUint32(g.value, true) : 0;
}

// A V8 engine stack overflow in the task (4-pre, V1): the stack pointer is not wrapped then.
export const isStackError = (e) => e instanceof RangeError && /call stack/i.test(e.message);

// The outcome of `handle` (API.md 4.1): a host block `[len u32][CBOR]`. JS reads it and frees it at once (PLAN.md 12,
// "Decisions on the 12-pre findings"). `refs`: the ref table of the task (a `Ref` in the outcome, for example a stream).
export function readOutcome(x, blk, refs) {
  const len = new DataView(x.memory.buffer).getUint32(blk, true);
  try {
    return fromJs(new Uint8Array(x.memory.buffer, blk + 4, len), refs);
  } finally {
    x.res_free(blk);
  }
}

// Log lines of the host (`dbg`): read them and free them. Call after each `handle` and
// each `task_abort`. The host blocks have owner 0, so a trap does not free them.
export function drainLog(x, onLog) {
  const n = x.log_len();
  if (n === 0) return;
  const w = new Uint32Array(x.memory.buffer, x.log_ptr(), n);
  for (let i = 0; i + 2 < n; i += 3) {
    const text = dec.decode(new Uint8Array(x.memory.buffer, w[i], w[i + 1]));
    onLog?.(w[i + 2], text);
  }
  x.log_clear();
}

// The counters of the host (PLAN.md M11, H3, 4g, 4h): the exports of one instance, in one record.
// `heapUsed`: bytes of the units in use. `heapBytes`: bytes of the pool. `livePeak`: the peak of `liveBytes`.
// `reclaimWalks`, `reclaimBytes`: the page reserve gave pages back under pressure. `leakedAtEnd`: the bytes
// that the host freed at the end of tasks. `idleResets`, `idleResetBytes` (H2). `alarms`: unclean traps the
// host saw. `doubleFrees`, `deallocMiss`: the allocator caught a wrong free. `sumChecks`: sums checked at a resume.
export function hostCounters(x) {
  return {
    heapUsed: x.heap_used(), heapBytes: x.heap_bytes(), liveBytes: x.live_bytes(), livePeak: x.live_peak(),
    reclaimWalks: x.reclaim_walks(), reclaimBytes: x.reclaim_bytes(), leakedAtEnd: x.leaked_at_end(),
    idleResets: x.idle_resets(), idleResetBytes: x.idle_reset_bytes(), alarms: x.alarms(),
    doubleFrees: x.double_frees(), deallocMiss: x.dealloc_miss(), sumChecks: x.sum_checks(),
  };
}

// The word that marks a free small block: random for each instance, so live
// data matches it only by chance (as the glibc tcache key).
export const freeMark = (x) => x.set_free_mark(crypto.getRandomValues(new Uint32Array(1))[0] | 1);

// Shim option `resumeCheck` (PLAN.md 12b) to the sum mode of the host. "always": a sum at each
// wait, a check at each resume after other code ran. "afterAlarm": a check only after an alarm.
// "off": no sums (bench only, 12f: the production host refuses it, `set_sum` gives 0).
export const SUM_MODES = { always: 2, afterAlarm: 1, off: 0 };
// A bench host has the test exports of PLAN.md 7a (`bench/platform/main.roc`). The production host has none of them.
export const isBenchHost = (module) => WebAssembly.Module.exports(module).some((e) => e.name === 'stats_reset');
// `task_abort` gives maxInt (-1 in JS) for an unclean trap, maxInt - cause for an alarm at resume.
export const ALARM_OF = { [-1]: 'trap', [-2]: 'sum', [-3]: 'block' };
// Codes of `check_heap()` (PLAN.md 12d, `hostlib/alloc.zig` CHECK_*, `host/host.zig`). -1: the check trapped.
export const CHECK_NAMES = {
  [-1]: 'trap in the check', 1: 'pool bounds', 2: 'free runs', 3: 'free bits', 4: 'page reserve', 5: 'task slots',
  6: 'small page', 7: 'free list of a small page', 8: 'pages with room', 9: 'large block', 10: 'unit in no place or in two',
  11: 'unit or byte counts', 12: 'constant data', 13: 'host globals', 14: 'wait records', 15: 'log',
  16: 'a trapped task is not aborted',
};
export const CHECK_BUSY = 16;
// Shim option `heapCheckEvery` (PLAN.md 12e): the global check after this many requests. The
// smallest round number that keeps the check at or below 0.1 % of the CPU time (`bench/checkcost.mjs`).
export const HEAP_CHECK_EVERY = 100;

// The event (a JS value, `js/events.js`) as CBOR in a js_alloc block: [ptr, len] for `handle`. null: out of memory.
// `bytes`: the CBOR of the event (`eventBytes`), made before the task enters wasm.
export function encEvent(x, bytes) {
  const p = x.js_alloc(bytes.length);
  if (!p) return null;
  new Uint8Array(x.memory.buffer).set(bytes, p);
  return [p, bytes.length];
}

// The CBOR of an event (J1 to J7). An object that is not data becomes a ref of the task (`refs`). Throws for a value
// that cannot cross (J1, J3).
export const eventBytes = (event, refs) => toJs(event, refs).slice();

// The level of a log line of the host: a `crash` text (and a bad event, `host/host.zig` `badEvent`), or a `dbg` line.
export const LOG_CRASH = 0;
export const LOG_DBG = 1;
