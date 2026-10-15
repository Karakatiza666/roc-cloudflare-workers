// JS side of programs (API.md 6.2): run a decoded program against the roots of one task.
import { encode, decode } from './codec.mjs';

const plain = (v) => { const p = Object.getPrototypeOf(v); return p === Object.prototype || p === null; };

// J1 to J7: what the last slot becomes.
export function toData(v, refs) {
  if (v === null || typeof v !== 'object') return typeof v === 'function' ? refs.add(v) : v;
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (Array.isArray(v)) return v.map((x) => toData(x, refs));
  if (v instanceof Date) return v.getTime();
  if (v instanceof Map || (typeof Headers !== 'undefined' && v instanceof Headers) || v instanceof URLSearchParams) return [...v.entries()];
  if (v instanceof Error) return v;
  if (plain(v)) { const o = {}; for (const k of Object.keys(v)) o[k] = toData(v[k], refs); return o; }
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

// Returns { status, bytes }. mode 'await' awaits each thenable (OP1); 'call' gives status 2 on one.
export async function run(bytes, roots, refs, mode) {
  const slots = [];
  const fromRef = (id) => refs.get(id);
  try {
    const ops = decode(bytes, fromRef);
    const target = (t) => {
      if (t && t.length === 2 && t[0] === 'root') { if (!(t[1] in roots)) throw new Bad(`unknown root ${t[1]}`); return roots[t[1]]; }
      if (t && t.length === 2 && t[0] === 'slot') { if (t[1] >= slots.length) throw new Bad(`slot ${t[1]}`); return slots[t[1]]; }
      return t; // a Ref, already resolved by decode
    };
    const arg = (a) => (a[0] === 'lit' ? a[1] : target(a));
    for (const [kind, t, name, x] of ops) {
      const o = target(t);
      let r;
      switch (kind) {
        case 'get': r = o[name]; break;
        case 'set': o[name] = arg(x); r = undefined; break;
        case 'call': r = o[name](...x.map(arg)); break;
        case 'new': r = new o[name](...x.map(arg)); break;
        case 'fields': r = Object.fromEntries(name.map((k) => [k, o[k]])); break;
        case 'keep': r = { $keep: o }; break;
        default: throw new Bad(`op ${kind}`);
      }
      if (r && typeof r.then === 'function') {
        if (mode === 'call') return { status: 2, bytes: encode(new Error('a promise in call!')) };
        r = await r;
      }
      slots.push(r);
    }
    const last = slots[slots.length - 1];
    const out = last && last.$keep !== undefined ? refs.add(last.$keep) : toData(last, refs);
    return { status: 0, bytes: encode(out, (o) => o.$ref) };
  } catch (e) {
    return { status: e instanceof Bad ? BAD : 1, bytes: encode(e instanceof Error ? e : new Error(String(e))) };
  }
}
