// The program interpreter (API.md 6.2): the ops of one crossing, run against the roots of one task.
// A program is the `Js` array that `Js.program` of Roc makes (OP5), decoded by `fromJs`:
//   ["get", target, name]            ["set", target, name, arg]       ["call" | "start" | "new", target, name, [args]]
//   ["fields", target, [names]]      ["keep", target]                 ["array", [args]]
//   ["record", [[key, arg], ...]]    ["par" | "race", [[ops], ...]]
//   target: ["root", name], ["slot", n] or ["ref", object];  arg: ["lit", value] or ["slot", n]
// Statuses (API.md 4): 0 the last slot, 1 a throw or a rejection, 2 a promise in `call!`, 3 a bad program.
import { Kept } from './values.js';

export const OK = 0, THROWN = 1, PROMISE = 2, BAD = 3;

// Status 3: a slot out of range, an unknown root, op or shape. A platform bug: the module crashes.
export class BadProgram extends Error {
  constructor(message) { super(message); this.name = 'BadProgram'; }
}
// Status 2: an op of a `call!` gave a promise (OP1). The program needs `await!`.
export class PromiseInCall extends Error {
  constructor(message) { super(message); this.name = 'PromiseInCall'; }
}

const isThenable = (v) => v !== null && (typeof v === 'object' || typeof v === 'function') && typeof v.then === 'function';
const isName = (v) => typeof v === 'string';
const bad = (m) => { throw new BadProgram(m); };

// Status of a throw: 3 and 2 by class, else 1.
export const statusOf = (e) => (e instanceof BadProgram ? BAD : e instanceof PromiseInCall ? PROMISE : THROWN);
// What a status 1 gives to Roc: an Error (J6). A thrown value that is not an Error becomes one.
export const errorOf = (e) => (e instanceof Error || (typeof DOMException !== 'undefined' && e instanceof DOMException) ? e : new Error(String(e)));

// The slots of one list of ops. `kept[i]`: slot i is the result of `Keep` (a Ref, also for a plain value).
class Frame {
  constructor(ctx) { this.ctx = ctx; this.slots = []; this.kept = []; }
  slot(n) {
    if (!Number.isInteger(n) || n < 0 || n >= this.slots.length) bad(`slot ${n} is not an earlier slot (there are ${this.slots.length})`);
    return this.slots[n];
  }
  target(t) {
    if (!Array.isArray(t) || t.length !== 2) bad('a target must be ["root", name], ["slot", n] or ["ref", object]');
    switch (t[0]) {
      case 'root': {
        const roots = this.ctx.roots;
        if (!isName(t[1]) || !Object.hasOwn(roots, t[1])) bad(`unknown root ${String(t[1])}`);
        return roots[t[1]];
      }
      case 'slot': return this.slot(t[1]);
      case 'ref': return t[1];
      default: return bad(`unknown target ${String(t[0])}`);
    }
  }
  arg(a) {
    if (!Array.isArray(a) || a.length !== 2) bad('an argument must be ["lit", value] or ["slot", n]');
    if (a[0] === 'lit') return a[1];
    if (a[0] === 'slot') return this.slot(a[1]);
    return bad(`unknown argument ${String(a[0])}`);
  }
  args(list) {
    if (!Array.isArray(list)) bad('arguments must be a list');
    return list.map((a) => this.arg(a));
  }
  // The value that a list of ops gives: its last slot, as a Ref when `Keep` made it.
  last() {
    const n = this.slots.length;
    if (n === 0) return undefined;
    return this.kept[n - 1] ? new Kept(this.slots[n - 1]) : this.slots[n - 1];
  }
}

// One op that needs no wait. Returns the value of the slot. `par` and `race` are not here.
function step(f, op) {
  const [kind, t, name, x] = op;
  switch (kind) {
    case 'get': {
      if (op.length !== 3 || !isName(name)) bad('get needs a target and a name');
      const o = f.target(t);
      return o === null || o === undefined ? undefined : o[name]; // OP7: as `?.`
    }
    case 'set': {
      if (op.length !== 4 || !isName(name)) bad('set needs a target, a name and an argument');
      const o = f.target(t);
      o[name] = f.arg(x); // throws on null and undefined (OP7)
      return undefined;
    }
    case 'call': case 'start': {
      if (op.length !== 4 || !isName(name)) bad(`${kind} needs a target, a name and arguments`);
      const o = f.target(t), args = f.args(x);
      return o[name](...args);
    }
    case 'new': {
      if (op.length !== 4 || !isName(name)) bad('new needs a target, a name and arguments');
      const o = f.target(t), args = f.args(x);
      return new o[name](...args);
    }
    case 'fields': {
      if (op.length !== 3 || !Array.isArray(name) || !name.every(isName)) bad('fields needs a target and a list of names');
      const o = f.target(t);
      if (o === null || o === undefined) return undefined; // OP7
      const r = {};
      for (const k of name) r[k] = o[k];
      return r;
    }
    case 'keep':
      if (op.length !== 2) bad('keep needs a target');
      return f.target(t);
    case 'array':
      if (op.length !== 2) bad('array needs a list of arguments');
      return f.args(t);
    case 'record': {
      if (op.length !== 2 || !Array.isArray(t)) bad('record needs a list of [key, argument]');
      const r = {};
      for (const kv of t) {
        if (!Array.isArray(kv) || kv.length !== 2 || !isName(kv[0])) bad('a record field must be [key, argument]');
        r[kv[0]] = f.arg(kv[1]);
      }
      return r;
    }
    default:
      return bad(`unknown op ${String(kind)}`);
  }
}

const opsOf = (ops) => (Array.isArray(ops) && ops.every(Array.isArray) ? ops : bad('a program must be a list of ops'));
const branchesOf = (op) => (op.length === 2 && Array.isArray(op[1]) ? op[1].map(opsOf) : bad(`${op[0]} needs a list of branches`));

// Runs the ops with no wait (`call!`). Throws a PromiseInCall for a promise (OP1) and for `par` and `race`
// (they always give a promise, OP6, OP8). Returns the value of the last slot.
export function runCall(ops, ctx) {
  const f = new Frame(ctx);
  opsOf(ops).forEach((op, i) => {
    if (op[0] === 'par' || op[0] === 'race') {
      branchesOf(op);
      throw new PromiseInCall(`op ${i} (${op[0]}) gives a promise: the program needs await!`);
    }
    const r = step(f, op);
    if (op[0] !== 'start' && op[0] !== 'keep' && isThenable(r)) {
      // The promise is dropped: a rejection must not be an unhandled rejection.
      Promise.resolve(r).catch(() => {});
      throw new PromiseInCall(`op ${i} (${op[0]}) gave a promise: the program needs await!`);
    }
    f.slots.push(r);
    f.kept.push(op[0] === 'keep');
  });
  return f.last();
}

// One branch of `par` or `race`: [status, value]. A status 3 is thrown: it makes the whole program status 3.
async function branch(ops, ctx) {
  try {
    return [OK, await runAwait(ops, ctx)];
  } catch (e) {
    if (e instanceof BadProgram) throw e;
    return [statusOf(e), errorOf(e)];
  }
}

// Runs the ops with waits (`await!`): each thenable result is awaited before the next op, except the
// results of `start` and `keep` (OP1). Returns the value of the last slot.
export async function runAwait(ops, ctx) {
  const f = new Frame(ctx);
  for (const op of opsOf(ops)) {
    let r;
    if (op[0] === 'par') {
      // OP6: all branches at the same time, each with its own slots.
      r = await Promise.all(branchesOf(op).map((b) => branch(b, ctx)));
    } else if (op[0] === 'race') {
      r = await race(branchesOf(op), ctx);
    } else {
      r = step(f, op);
      if (op[0] !== 'start' && op[0] !== 'keep' && isThenable(r)) r = await r;
    }
    f.slots.push(r);
    f.kept.push(op[0] === 'keep');
  }
  return f.last();
}

// OP8: the first branch to settle wins: [index, [status, value]]. Each branch has its own AbortSignal (the root
// `signal`), and the others are aborted. They go on in JS until they see it; their results are dropped.
async function race(branches, ctx) {
  if (branches.length === 0) bad('a race with no branch never settles');
  const ctls = branches.map(() => new AbortController());
  const runs = branches.map((b, i) => {
    const signal = ctx.signal ? AbortSignal.any([ctx.signal, ctls[i].signal]) : ctls[i].signal;
    return branch(b, { ...ctx, signal, roots: { ...ctx.roots, signal } }).then((r) => [i, r], (e) => [i, e]);
  });
  const [i, r] = await Promise.race(runs);
  ctls.forEach((c, j) => { if (j !== i) c.abort(new DOMException('the branch lost the race', 'AbortError')); });
  if (r instanceof BadProgram) throw r;
  return [i, r];
}
