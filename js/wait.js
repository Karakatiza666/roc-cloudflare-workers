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
