// The cancel of a task in the host (PLAN.md 2c, 3c). The wait imports are in bridge.js (API.md 4.1).

// The host frees the wait record and pages of cancelled task `t`, once: at the cancel when
// it waits, else at its next wait. A trap in `task_cancel` shows a damaged instance: an alarm
// (PLAN.md 12c). `onTrap(x, t, e)` makes it. The task is cancelled in any case.
export function hostCancel(x, t, onTrap) {
  if (t.hostFreed) return;
  t.hostFreed = true;
  try {
    x.task_cancel(t.id);
  } catch (e) {
    onTrap?.(x, t, e);
  }
}

// End a cancelled task: status 5 makes it trap before it touches memory (3c), because the
// host has freed its record and pages. `ended5` tells the runner that this trap is a cancel.
export function end5(x, t, onTrap) {
  hostCancel(x, t, onTrap);
  t.ended5 = true;
  return 5;
}

// The owner of the shadow stack (first release run, PLAN.md "Status of the first release run"). One task at a time
// runs in wasm: from its entry (`handle`, or the resume after a wait) to its next wait or its end. A trap shows in JS
// only in a later promise job (the catch of `run`), and until that catch calls `task_abort` the host state is the
// state of the trap: the task is still the owner, and after a stack overflow the stack pointer is wrapped. A second
// task that enters wasm in that window (a new `run`, or the resume of a wait) traps too, and both traps are alarms.
// So each entry waits until the owner of the instance (`cell.inWasm`) left: at its wait (`js_await`) or after the
// catch of its `run`. `enterWasm` returns undefined when the stack is free (no extra promise job), else a promise.
// `owner`: any object (a run before its task exists, then the task). Idempotent for the current owner.
// A dropped instance (`cell.dead`, M1) has no owner: its cancelled tasks only end there.
export function enterWasm(cell, owner) {
  if (cell.dead) return undefined;
  if (cell.inWasm == null || cell.inWasm === owner) {
    cell.inWasm = owner;
    return undefined;
  }
  return (async () => {
    while (!cell.dead && cell.inWasm != null && cell.inWasm !== owner) await new Promise((r) => (cell.wasmWaiters ??= []).push(r));
    cell.inWasm = owner;
  })();
}

// `owner` left wasm (a wait, or the end of its run after `task_abort`): the next waiting entry goes on.
export function leaveWasm(cell, owner) {
  if (!cell || cell.inWasm !== owner) return;
  cell.inWasm = null;
  const w = cell.wasmWaiters;
  if (!w?.length) return;
  cell.wasmWaiters = [];
  for (const r of w) r();
}
