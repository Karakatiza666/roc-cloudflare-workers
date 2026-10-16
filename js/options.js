// The options of `makeHandler(module, opts)` (PLAN.md 4, "Shim options"). `checkOptions` throws at once for an
// unknown name or a bad value, so a typo shows at load and not at the first request.
import { SUM_MODES } from './host.js';
import { BUDGET_OPTS } from './budget.js';

const isNum = (v) => typeof v === 'number' && !Number.isNaN(v);
const isInt = (v) => Number.isSafeInteger(v);
const isFn = (v) => typeof v === 'function';
const isBool = (v) => typeof v === 'boolean';
const isOp = (v) => isFn(v) || (v !== null && typeof v === 'object');
const ms = [(v) => isNum(v) && v > 0, 'a number of ms above 0'];
const fn = [isFn, 'a function'];

// name -> [test, what a good value is]. The first group is the table of PLAN.md 4 that the runner has today.
const RULES = {
  isolateBytes: [(v) => isNum(v) && v > 0 && v < Infinity, 'a number of bytes above 0'],
  jsReserveBytes: [(v) => isNum(v) && v >= 0 && v < Infinity, 'a number of bytes, 0 or more'],
  maxInstanceBytes: [(v) => isNum(v) && v > 0, 'a number of bytes above 0 (Infinity: no cap)'],
  growStepBytes: [(v) => isInt(v) && v > 0, 'an integer number of bytes above 0'],
  graceMs: [(v) => isNum(v) && v >= 0 && v < Infinity, 'a number of ms, 0 or more'],
  queueLimit: [(v) => isInt(v) && v >= 0, 'an integer, 0 or more'],
  resumeCheck: [(v) => typeof v === 'string' && Object.hasOwn(SUM_MODES, v), `one of ${Object.keys(SUM_MODES).map((k) => `"${k}"`).join(', ')}`],
  heapCheckEvery: [(v) => isInt(v) && v >= 0, 'an integer, 0 (off) or more'],
  heapCheckWhenIdle: [isBool, 'true or false'],
  taskDeadlineMs: ms,
  // The other deadlines of API.md 10.2.
  wallMs: ms,
  initMs: ms,
  afterRespondMs: ms,
  // API.md 6.4: `ops`, the JS functions of the app (the root `ops` of a program). A value is a function or an object (a
  // library, a binding): a program reaches its methods with `Get` and `Call` (PLAN.md 8a O4). RS2: the size of the pin table.
  ops: [(v) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.values(v).every(isOp), 'an object whose values are functions or objects'],
  pinLimit: [(v) => isInt(v) && v >= 0, 'an integer, 0 or more'],
  // API.md 10.1: the Workers handler names that reach the app as `Other` (for example "queue" in phase A).
  other: [(v) => Array.isArray(v) && new Set(v).size === v.length && v.every((n) => typeof n === 'string' && /^[A-Za-z_$][\w$]*$/.test(n) && !RESERVED.has(n)), 'an array of handler names, each once, not fetch, scheduled or constructor'],
  // Hooks of the runner that tests use.
  log: fn,
  onLog: fn,
  now: fn,
  noFallback: [isBool, 'true or false'],
  variant: [(v) => v === 'a' || v === 'b', '"a" or "b"'],
};

// Names that `other` cannot take: the class has these methods already.
const RESERVED = new Set(['fetch', 'scheduled', 'constructor']);

// Options of the table that a later step adds (none now).
const LATER = {};

// Returns a copy of `opts` when each option is known and has a good value, else throws.
export function checkOptions(opts = {}) {
  if (opts === null || typeof opts !== 'object' || Array.isArray(opts)) throw new TypeError('makeHandler: opts must be an object');
  for (const [k, v] of Object.entries(opts)) {
    if (v === undefined) continue;
    const rule = RULES[k];
    if (!rule) {
      const hint = LATER[k] ? `: it is not built yet (PLAN.md ${LATER[k]})` : `. Known options: ${Object.keys(RULES).join(', ')}`;
      throw new Error(`makeHandler: unknown option "${k}"${hint}`);
    }
    if (!rule[0](v)) throw new TypeError(`makeHandler: option "${k}" must be ${rule[1]}, got ${isFn(v) ? 'a function' : JSON.stringify(v)}`);
  }
  // The memory for wasm is isolateBytes less jsReserveBytes (M3): it must not be empty.
  const isolate = opts.isolateBytes ?? BUDGET_OPTS.isolateBytes;
  const reserve = opts.jsReserveBytes ?? BUDGET_OPTS.jsReserveBytes;
  if (reserve >= isolate) throw new RangeError(`makeHandler: jsReserveBytes (${reserve}) must be less than isolateBytes (${isolate})`);
  return { ...opts };
}
