// The imports of the bridge (API.md 4.1): `js_await` (wrapped in `WebAssembly.Suspending`) and `js_call`.
// Both are `(task_id, arg_ptr, arg_len, out_ptr) -> status`. JS reads the program from the argument block before
// its first await, runs it against the context of the task, and writes the result straight into a `js_alloc`
// block (`Writer` with `grow`), then `[ptr, len]` at `out_ptr`. Status 0 to 3 (API.md 4), 4: `js_alloc` gave 0
// (no block), 5: cancelled (PLAN.md 3c). Neither import ever throws or rejects: a throw into a waiting task would
// skip `waitEnd` and lose the task (PLAN.md 2b).
import { fromJs, toJs, Writer, Refs } from './values.js';
import { runAwait, runCall, statusOf, errorOf, BadProgram, OK, THROWN, BAD } from './program.js';
import { makeHelpers } from './helpers.js';
import { end5 } from './wait.js';

export const STATUS_OOM = 4;
class OutOfMemory extends Error {}

// The first size of a result block. A larger result grows it (a new block, the old one freed).
const FIRST_BLOCK = 256;

// The CBOR of `value` (status 0) or of an Error (status 1 to 3) in a `js_alloc` block, and `[ptr, len]` at `out`.
// A value that breaks a conversion rule (J1, J3, a TooLarge of `pack`) is status 1 with that error. Returns the
// status, or 4 when there is no memory for the block.
export function writeResult(x, out, status, value, refs) {
  let p = x.js_alloc(FIRST_BLOCK);
  if (!p) return STATUS_OOM;
  let size = FIRST_BLOCK;
  const grow = (min, old, used) => {
    const n = Math.max(min, size * 2);
    const q = x.js_alloc(n);
    if (!q) throw new OutOfMemory();
    // A js_alloc can grow the memory and detach the old view: copy by address.
    new Uint8Array(x.memory.buffer).copyWithin(q, p, p + used);
    x.res_free(p);
    p = q;
    size = n;
    return new Uint8Array(x.memory.buffer, q, n);
  };
  try {
    const w = new Writer(new Uint8Array(x.memory.buffer, p, size), { grow, copies: true });
    try {
      toJs(status === OK ? value : errorOf(value), refs, w);
    } catch (e) {
      if (e instanceof OutOfMemory) throw e;
      // J1, J3, TooLarge: the value cannot cross. Status 1 with the error, in the same block.
      w.reset();
      toJs(errorOf(e), refs, w);
      status = THROWN;
    }
    const dv = new DataView(x.memory.buffer);
    dv.setUint32(out, p, true);
    dv.setUint32(out + 4, w.n, true);
    return status;
  } catch {
    // No memory for the block, or a trap in `js_alloc` (a damaged instance): no block, status 4.
    try {
      x.res_free(p);
    } catch {}
    return STATUS_OOM;
  }
}

// cell: { x, gate, cancelTrap } of the instance. tasks: the task table (null in some tests). shim: { ops, pins, log,
// crossings }: `crossings` counts the calls of `js_await` and `js_call` (`{ await, call }`, PLAN.md 8c).
export function makeBridge(cell, tasks, shim) {
  // The context of a program of task `t` (OP3): its roots, its ref table (RS1), its signal (OP8: aborted at the
  // end of the task). One for each task, made at its first program.
  const contextOf = (t) => {
    if (t?.pctx) return t.pctx;
    const ctl = new AbortController();
    const roots = { env: t?.env, ctx: t?.ctx, event: t?.event, global: globalThis, ops: shim.ops ?? {}, signal: ctl.signal };
    const c = { roots, refs: t?.refs ?? new Refs(), signal: ctl.signal, ctl };
    roots.pf = makeHelpers(t, c, shim, tasks);
    if (t) t.pctx = c;
    return c;
  };
  // The program from the argument block: a bad block is a bad program (status 3).
  const read = (x, ap, al, c) => {
    try {
      return fromJs(new Uint8Array(x.memory.buffer, ap, al), c.refs);
    } catch (e) {
      throw new BadProgram(`the program is not a Js value: ${e.message}`);
    }
  };

  // The crossings of the instance (`stats.crossings` of the runner): one count for each import call.
  const crossings = shim.crossings ?? { await: 0, call: 0 };
  async function js_await(id, ap, al, out) {
    crossings.await++;
    const x = cell.x;
    const t = tasks?.get(id);
    // A task that was cancelled while it ran ends at its next wait.
    if (t?.cancelled) return end5(x, t, cell.cancelTrap);
    try {
      const c = contextOf(t);
      let res;
      try {
        // Read before the first await: the block is in memory that other tasks use next.
        const prog = read(x, ap, al, c);
        const running = runAwait(prog, c).then((v) => [OK, v], (e) => [statusOf(e), errorOf(e)]);
        if (t) {
          // A cancel wins the race, so the suspended stack always ends (PLAN.md 3.0: it is never freed).
          const cancelled = tasks.waitStart(t);
          try {
            res = await Promise.race([running, cancelled]);
          } finally {
            tasks.waitStop(t);
          }
          if (t.cancelled) return end5(x, t, cell.cancelTrap);
        } else res = await running;
      } catch (e) {
        res = [statusOf(e), errorOf(e)];
      }
      // 12c: a global check that is due runs before the resume. A failed check cancels this task.
      cell.gate?.();
      if (t?.cancelled) return end5(x, t, cell.cancelTrap);
      return writeResult(x, out, res[0], res[1], c.refs);
    } catch {
      if (t?.cancelled) return end5(x, t, cell.cancelTrap);
      return STATUS_OOM;
    }
  }

  // No wait: a promise is status 2 (OP1). The task is not cancelled here: a cancel stops a task at a wait.
  function js_call(id, ap, al, out) {
    crossings.call++;
    const x = cell.x;
    try {
      const c = contextOf(tasks?.get(id));
      let res;
      try {
        res = [OK, runCall(read(x, ap, al, c), c)];
      } catch (e) {
        res = [statusOf(e), errorOf(e)];
      }
      return writeResult(x, out, res[0], res[1], c.refs);
    } catch {
      return STATUS_OOM;
    }
  }

  return { js_await, js_call, contextOf };
}

export { BAD };
