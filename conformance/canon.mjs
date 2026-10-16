// The text of a JSON value with the keys of each object in order: Roc writes the fields of a record in name order, so a
// check compares `canon(got)` with `canon(want)` (used by the checks of the "other bindings", PLAN.md 8f part 4).
export const canon = (v) => JSON.stringify(v, (k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : 1))) : x));
