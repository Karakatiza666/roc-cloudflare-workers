// JS values to and from the `Js` bytes (API.md 5, rules J1 to J7), and `Packed` values (API.md 5.2).
// The CBOR profile is in cbor.js. The ref table of a task (API.md RS1) is `Refs`.
import { Writer, MAX_DEPTH, depthError, decode } from './cbor.js';

export { Writer, TooLarge, BufferFull, decode, MAX_DEPTH } from './cbor.js';

// The ref table of one task. One id for each object: the same object gives the same id (RS1).
// Ids start at 1. The table keeps its objects until `clear()` (the end, the trap or the cancel of the task).
// `count`: an object whose `refsLive` counts the refs of all tables (the task table, PLAN.md 10c), or none.
export class Refs {
  constructor(count) { this.ids = new Map(); this.objs = [undefined]; this.count = count; }
  idOf(obj) {
    let id = this.ids.get(obj);
    if (id === undefined) {
      id = this.objs.length; this.objs.push(obj); this.ids.set(obj, id);
      if (this.count) this.count.refsLive++;
    }
    return id;
  }
  get(id) {
    if (!Number.isInteger(id) || id < 1 || id >= this.objs.length) throw new RangeError(`unknown ref ${id}`);
    return this.objs[id];
  }
  get size() { return this.objs.length - 1; }
  clear() {
    if (this.count) this.count.refsLive -= this.objs.length - 1;
    this.ids.clear(); this.objs.length = 1;
  }
}

// Marks a value to be written as `Packed` (tag 24 and the CBOR of the value as a byte string), inside a tree.
// For a value at the top, use `pack`. maxBytes: the limit of the content (TooLarge).
// budget: an object `{ left }` that some Packed values share (`pf.packEach`): the limit of all of them together.
export class Packed {
  constructor(value, maxBytes = Infinity, budget = null) { this.value = value; this.maxBytes = maxBytes; this.budget = budget; }
}

// Marks a value to be written as a `Js` tree (J1 to J7) with a limit of its CBOR size: more is a TooLarge
// (`pf.limit`, `D1.rows!`, MC11).
export class Limited {
  constructor(value, maxBytes) { this.value = value; this.maxBytes = maxBytes; }
}

// Marks a value to be written as a `Ref`, also a plain value or a promise (the op `Keep`, API.md 6.2).
export class Kept {
  constructor(value) { this.value = value; }
}

const TAG_PACKED = new Uint8Array([0xd8, 0x18]);
const REF_HEAD = new Uint8Array([0xd8, 0x1b, 0x82, 0x63, 0x52, 0x65, 0x66]); // 27, [2], "Ref"
const ERROR_HEAD = new Uint8Array([0xd8, 0x1b, 0x83, 0x65, 0x45, 0x72, 0x72, 0x6f, 0x72]); // 27, [3], "Error"

// J1: the range of an Int is i64. Typed data (Packed) also takes up to 2^64 - 1, for a U64.
const I64_MIN = -(1n << 63n), I64_MAX = (1n << 63n) - 1n, U64_MAX = (1n << 64n) - 1n;

const isHeaders = (v) => typeof Headers !== 'undefined' && v instanceof Headers;
const isDomException = (v) => typeof DOMException !== 'undefined' && v instanceof DOMException;

function ref(w, v, refs, typed) {
  if (typed) throw new TypeError(`Packed data cannot hold a ${typeof v === 'object' ? 'class instance' : typeof v}: it has no codec (J7)`);
  const id = refs.idOf(v);
  w.raw(REF_HEAD); w.head(0, id);
}

// typed: the value goes in a Packed (the data model of the Cbor format of Roc): no Ref, no nested Packed.
function put(w, v, refs, level, typed) {
  switch (typeof v) {
    case 'undefined': return w.undef();
    case 'boolean': return w.bool(v);
    case 'number': return Number.isSafeInteger(v) ? w.int(v) : w.float(v);
    case 'string': return w.text(v);
    case 'bigint':
      if (v < I64_MIN || v > (typed ? U64_MAX : I64_MAX)) throw new RangeError(`BigInt ${v} is outside ${typed ? 'the range of I64 and U64' : 'i64'} (J1)`);
      return w.bigint(v);
    case 'function': case 'symbol': return ref(w, v, refs, typed);
  }
  if (v === null) return w.null();
  if (Array.isArray(v)) {
    if (level >= MAX_DEPTH) throw depthError();
    w.array(v.length);
    for (let i = 0; i < v.length; i++) put(w, v[i], refs, level + 1, typed);
    return;
  }
  const proto = Object.getPrototypeOf(v);
  if (proto === Object.prototype || proto === null) {
    if (level >= MAX_DEPTH) throw depthError();
    const keys = Object.keys(v);
    w.map(keys.length);
    for (let i = 0; i < keys.length; i++) { w.key(keys[i]); put(w, v[keys[i]], refs, level + 1, typed); }
    return;
  }
  if (v instanceof Uint8Array) return w.bytes(v);
  if (v instanceof ArrayBuffer) return w.bytes(new Uint8Array(v));
  if (ArrayBuffer.isView(v)) return w.bytes(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
  if (v instanceof Date) return put(w, v.getTime(), refs, level, typed);
  if (v instanceof Map || isHeaders(v) || v instanceof URLSearchParams) {
    return put(w, Array.from(v.entries()), refs, level, typed);
  }
  if (v instanceof Error || isDomException(v)) {
    // Typed data has no Error: the `Cbor` format of Roc reads no tag (API.md 5.2).
    if (typed) throw new TypeError(`Packed data cannot hold an Error (${v.name}): it has no codec`);
    w.raw(ERROR_HEAD); w.text(String(v.name)); return w.text(String(v.message));
  }
  if (v instanceof Kept) return ref(w, v.value, refs, typed);
  if (v instanceof Packed) {
    if (typed) throw new TypeError('Packed data cannot hold a Packed value');
    if (!v.budget) return packed(w, v.value, refs, level, v.maxBytes);
    const before = w.n;
    packed(w, v.value, refs, level, Math.min(v.maxBytes, v.budget.left));
    v.budget.left -= w.n - before;
    return;
  }
  if (v instanceof Limited) {
    const saved = w.limit;
    w.limit = Math.min(saved, w.n + v.maxBytes);
    try {
      put(w, v.value, refs, level, typed);
    } finally {
      w.limit = saved;
    }
    return;
  }
  return ref(w, v, refs, typed);
}

function packed(w, value, refs, level, maxBytes) {
  w.raw(TAG_PACKED);
  w.packed(maxBytes, () => put(w, value, refs, level, true));
}

// A JS value to `Js` bytes (J1 to J7). Objects that are not data become `Ref(id)` of `refs`.
// writer: a Writer (a growable one is the default). Gives a view of its bytes (done()).
export function toJs(value, refs, writer = new Writer()) {
  put(writer, value, refs, 0, false);
  return writer.done();
}

// A JS value to a `Packed` value: tag 24 and the CBOR of the value as a byte string (API.md 5.2).
// opts.maxBytes: the limit of the CBOR of the value: more is a TooLarge (RangeError). opts.writer: as in toJs.
export function pack(value, opts = {}) {
  const w = opts.writer ?? new Writer();
  packed(w, value, null, 0, opts.maxBytes ?? Infinity);
  return w.done();
}

// `Js` bytes to a JS value. `Ref(id)` gives refs.get(id). `Packed` gives the value of its bytes.
// Int gives a Number up to 2^53 and a BigInt above, Bytes gives a Uint8Array (a copy).
export function fromJs(bytes, refs) {
  return decode(bytes, { ref: refs === undefined ? undefined : (id) => refs.get(id) });
}
