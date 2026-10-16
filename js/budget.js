// Memory budget of the isolate (PLAN.md M3 to M7, M10; steps 4b to 4e). It knows no wasm: the runner
// (`runner.js`) gives it the `WebAssembly.Memory` of each instance. The host asks it before each grow
// (`js_grow`, `hostlib/alloc.zig` `poolGrow`).

export const MB = 1 << 20;
const PAGE = 65536;

// Shim options and their defaults (PLAN.md 4, "Shim options").
export const BUDGET_OPTS = {
  isolateBytes: 128 * MB, // the Cloudflare limit
  jsReserveBytes: 48 * MB, // the part of the isolate for JS (3.0: the JS heap peaks at 46 MB)
  maxInstanceBytes: Infinity, // M5: a hard cap for one instance, none by default
  growStepBytes: PAGE, // M4, H9
  graceMs: 1000, // M7 step 2
  queueLimit: 100, // M9
};

const size = (m) => m.buffer.byteLength;
const mb = (n) => (n / MB).toFixed(1);

// opts: the BUDGET_OPTS keys, `now` (a clock for tests), `log(text)`: one line for each denied grow (M11).
export function makeBudget(opts = {}) {
  const o = { ...BUDGET_OPTS };
  for (const k of Object.keys(BUDGET_OPTS)) if (opts[k] !== undefined) o[k] = opts[k];
  // The bytes for wasm memory. A test can make the isolate smaller.
  const limit = o.isolateBytes - o.jsReserveBytes;
  const now = opts.now ?? (() => Date.now());
  const log = opts.log ?? (() => {});
  const live = new Set(); // the memory of each instance in use
  const dropped = new Map(); // id -> bytes: dropped instances that are not collected yet (M10)
  let lastId = 0;
  let droppedBytes = 0;
  let deniedAt = -Infinity;
  let loneNext = false; // the next instance starts with no live instance (`startIdle`)
  let lone = null; // that instance, while it lives
  const stats = { asked: 0, denied: 0, deniedCap: 0, deniedBudget: 0, dropped: 0, collected: 0, idleStarts: 0, maxTotal: 0 };
  // M10: a dropped instance counts until V8 collects it. The callback only needs the id: it must not
  // hold the memory.
  const registry = new FinalizationRegistry((id) => {
    const n = dropped.get(id);
    if (n === undefined) return;
    dropped.delete(id);
    droppedBytes -= n;
    stats.collected++;
  });
  const total = () => {
    let n = droppedBytes;
    for (const m of live) n += size(m);
    return n;
  };
  const api = {
    limit,
    options: o,
    stats,
    // The bytes of the isolate that wasm memory uses now: live instances and dropped ones not yet collected.
    total,
    get droppedBytes() {
      return droppedBytes;
    },
    get droppedCount() {
      return dropped.size;
    },
    get liveCount() {
      return live.size;
    },
    // A new instance with memory `m`. Its first pages count at once.
    add(m) {
      live.add(m);
      if (loneNext) {
        lone = m;
        loneNext = false;
      }
      const t = total();
      if (t > stats.maxTotal) stats.maxTotal = t;
    },
    // M10: instance `m` is dropped. Its bytes stay in the budget until the callback.
    drop(m) {
      if (!live.delete(m)) return;
      if (m === lone) lone = null;
      const id = ++lastId;
      const n = size(m);
      dropped.set(id, n);
      droppedBytes += n;
      stats.dropped++;
      registry.register(m, id);
    },
    // M4, M5: may `m` grow by `pages`? 1: yes, 0: no (`js_grow`). A no is pressure (M7).
    ask(m, pages) {
      stats.asked++;
      const add = pages * PAGE;
      const mine = size(m);
      const t = lone === m && live.size === 1 ? mine : total();
      let why = '';
      if (mine + add > o.maxInstanceBytes) {
        why = `instance ${mb(mine)} MB + ${mb(add)} MB is over maxInstanceBytes ${mb(o.maxInstanceBytes)} MB`;
        stats.deniedCap++;
      } else if (t + add > limit) {
        why = `budget ${mb(t)} MB (${droppedBytes ? `${mb(droppedBytes)} MB dropped, not collected` : 'live'}) + ${mb(add)} MB is over ${mb(limit)} MB`;
        stats.deniedBudget++;
      }
      if (why) {
        stats.denied++;
        deniedAt = now();
        log(`grow denied: ${why}`);
        return 0;
      }
      if (t + add > stats.maxTotal) stats.maxTotal = t + add;
      return 1;
    },
    // M7 step 2: a grow was denied in the last `graceMs`.
    pressure() {
      return now() - deniedAt < o.graceMs;
    },
    // M1: after a replace the old instance may still count, and the new one does not fit next to it.
    // New requests wait for the callback (a shed). Not when no instance is dropped: the budget is too small for one instance.
    crowded() {
      return droppedBytes > 0 && total() > limit;
    },
    // M9, M10: no instance is live, so the dropped ones have no task: they are garbage that V8 frees under memory
    // pressure. The fallback queue starts one instance then, even when the dropped bytes say no: a request must
    // never wait for a GC (workerd cancels it as "hung"). While it is the only live instance, its grows do not count
    // the dropped bytes. Call it right before the instance is added (`add`). Returns false when an instance is live.
    startIdle() {
      if (live.size > 0) return false;
      if (droppedBytes > 0) {
        loneNext = true;
        stats.idleStarts++;
        log(`no instance is live: an instance starts although ${mb(droppedBytes)} MB of dropped instances are not collected`);
      }
      return true;
    },
    // M9: may a new instance start? `n`: the bytes that an instance needs, the largest size seen. Each live
    // instance keeps at least `n` for itself, so the grows of a running request are not denied by the start
    // of another one. One instance may always start when nothing else holds memory.
    fits(n) {
      let held = droppedBytes;
      for (const m of live) held += Math.max(size(m), n);
      return held + n <= limit || total() === 0;
    },
  };
  return api;
}
