// JS side of programs (API.md 6.2): run a decoded program against the roots of one task.
import { encode, decode } from './codec.mjs';

const plain = (v) => { const p = Object.getPrototypeOf(v); return p === Object.prototype || p === null; };

const MAX_DEPTH = 64;
const I64 = 2n ** 63n;

// J1 to J7: what the last slot becomes. A BigInt outside i64 (J1), or a depth above 64 or a cycle (J3), is a RangeError: status 1.
export function toData(v, refs, depth = 0) {
  if (depth > MAX_DEPTH) throw new RangeError(`deeper than ${MAX_DEPTH}, or a cycle`);
  if (typeof v === 'bigint' && (v < -I64 || v >= I64)) throw new RangeError(`BigInt ${v} is outside i64`);
  if (v === null || typeof v !== 'object') return typeof v === 'function' ? refs.add(v) : v;
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (Array.isArray(v)) return v.map((x) => toData(x, refs, depth + 1));
  if (v instanceof Date) return v.getTime();
  if (v instanceof Map || (typeof Headers !== 'undefined' && v instanceof Headers) || v instanceof URLSearchParams) return [...v.entries()];
  if (v instanceof Error) return v;
  if (plain(v)) { const o = {}; for (const k of Object.keys(v)) o[k] = toData(v[k], refs, depth + 1); return o; }
  return refs.add(v);
}

export class Refs {
  constructor() { this.objs = [undefined]; }
  add(o) { this.objs.push(o); return { $ref: this.objs.length - 1 }; }
  get(id) { if (id <= 0 || id >= this.objs.length) throw new Error(`bad ref ${id}`); return this.objs[id]; }
  clear() { this.objs.length = 1; }
}

const BAD = 3;
class Bad extends Error {}

// Runs one list of ops and gives its slots. mode 'await' awaits each thenable (OP1), except a `start`
// result. Mode 'call' gives status 2 on one. `par` runs its branches at the same time (OP6).
async function exec(ops, roots, refs, mode) {
  const slots = [];
  const target = (t) => {
    if (t && t.length === 2 && t[0] === 'root') { if (!(t[1] in roots)) throw new Bad(`unknown root ${t[1]}`); return roots[t[1]]; }
    if (t && t.length === 2 && t[0] === 'slot') { if (t[1] >= slots.length) throw new Bad(`slot ${t[1]}`); return slots[t[1]]; }
    return t; // a Ref, already resolved by decode
  };
  const arg = (a) => (a[0] === 'lit' ? a[1] : target(a));
  for (const op of ops) {
    const [kind, t, name, x] = op;
    let r;
    switch (kind) {
      case 'get': r = target(t)[name]; break;
      case 'set': target(t)[name] = arg(x); r = undefined; break;
      case 'call': case 'start': { const o = target(t); r = o[name](...x.map(arg)); break; }
      case 'new': { const o = target(t); r = new o[name](...x.map(arg)); break; }
      case 'fields': { const o = target(t); r = Object.fromEntries(name.map((k) => [k, o[k]])); break; }
      case 'keep': r = { $keep: target(t) }; break;
      case 'array': r = t.map(arg); break;
      case 'record': r = Object.fromEntries(t.map(([k, a]) => [k, arg(a)])); break;
      case 'par': {
        const done = await Promise.allSettled(t.map((branch) => exec(branch, roots, refs, mode)));
        r = done.map((d) => {
          if (d.status === 'fulfilled') return [0, d.value[d.value.length - 1]];
          if (d.reason instanceof Bad) throw d.reason; // status 3 for the whole program
          return [d.reason instanceof Promised ? 2 : 1, d.reason];
        });
        break;
      }
      default: throw new Bad(`op ${kind}`);
    }
    if (kind !== 'start' && r && typeof r.then === 'function') {
      if (mode === 'call') throw new Promised('a promise in call!');
      r = await r;
    }
    slots.push(r);
  }
  return slots;
}

class Promised extends Error {}

// Returns { status, bytes }.
export async function run(bytes, roots, refs, mode) {
  try {
    const ops = decode(bytes, (id) => refs.get(id));
    const slots = await exec(ops, roots, refs, mode);
    const last = slots[slots.length - 1];
    const out = last && last.$keep !== undefined ? refs.add(last.$keep) : toData(last, refs);
    return { status: 0, bytes: encode(out, (o) => o.$ref) };
  } catch (e) {
    const status = e instanceof Bad ? BAD : e instanceof Promised ? 2 : 1;
    return { status, bytes: encode(e instanceof Error ? e : new Error(String(e))) };
  }
}
