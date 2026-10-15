// JS side of the CBOR profile (API.md 5, AQ8). Same profile as Cbor.roc: definite lengths, text keys,
// integers as major types 0 and 1, floats as f64. A ref and an error are tag 27 (a "generic object":
// ["Ref", id], ["Error", name, message]), a registered tag, so a CBOR tool shows them.
const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder('utf-8', { fatal: true });

export class Writer {
  constructor(size = 1024) { this.buf = new Uint8Array(size); this.dv = new DataView(this.buf.buffer); this.n = 0; this.keys = keyBytes; }
  room(k) {
    if (this.n + k <= this.buf.length) return;
    const b = new Uint8Array(Math.max(this.buf.length * 2, this.n + k));
    b.set(this.buf.subarray(0, this.n)); this.buf = b; this.dv = new DataView(b.buffer);
  }
  head(major, x) {
    this.room(9);
    const m = major << 5, b = this.buf;
    if (x < 24) b[this.n++] = m | x;
    else if (x < 0x100) { b[this.n++] = m | 24; b[this.n++] = x; }
    else if (x < 0x10000) { b[this.n++] = m | 25; this.dv.setUint16(this.n, x); this.n += 2; }
    else if (x < 0x100000000) { b[this.n++] = m | 26; this.dv.setUint32(this.n, x); this.n += 4; }
    else { b[this.n++] = m | 27; this.dv.setBigUint64(this.n, BigInt(x)); this.n += 8; }
  }
  text(s) {
    const len = s.length;
    // ASCII fast path for short text (48 was the fastest of 8, 24, 48, 128 for D1 rows).
    if (len < 48) {
      this.room(2 + len);
      const b = this.buf, start = this.n + (len < 24 ? 1 : 2);
      let i = 0;
      for (; i < len; i++) { const c = s.charCodeAt(i); if (c > 0x7f) break; b[start + i] = c; }
      if (i === len) { this.head(3, len); this.n += len; return; }
    }
    // Reserve the head for the largest size, encode, then move the bytes if the head is smaller.
    const max = len * 3, hmax = max < 24 ? 1 : max < 0x100 ? 2 : max < 0x10000 ? 3 : 5;
    this.room(hmax + max);
    const r = utf8.encodeInto(s, this.buf.subarray(this.n + hmax));
    const h = r.written < 24 ? 1 : r.written < 0x100 ? 2 : r.written < 0x10000 ? 3 : 5;
    if (h !== hmax) this.buf.copyWithin(this.n + h, this.n + hmax, this.n + hmax + r.written);
    this.head(3, r.written); this.n += r.written;
  }
  // An object key: the same keys come in each row, so their bytes are kept.
  key(k) {
    let b = this.keys.get(k);
    if (b === undefined) {
      const w = new Writer(64); w.text(k); b = w.done().slice();
      if (this.keys.size < 256) this.keys.set(k, b);
    }
    this.room(b.length); this.buf.set(b, this.n); this.n += b.length;
  }
  bytes(u8) { this.head(2, u8.length); this.room(u8.length); this.buf.set(u8, this.n); this.n += u8.length; }
  done() { return this.buf.subarray(0, this.n); }
}

const MAX_DEPTH = 64;

// The bytes of object keys, shared by all writers: rows of one query have the same keys.
const keyBytes = new Map();

// Short ASCII text without TextDecoder, which costs much for each call.
function shortText(u8, at, n) {
  let s = '';
  for (let i = at; i < at + n; i++) { const c = u8[i]; if (c > 0x7f) return fromUtf8.decode(u8.subarray(at, at + n)); s += String.fromCharCode(c); }
  return s;
}

// toRef(obj) -> id: a value that is not plain data stays in JS (J7).
export function put(w, v, toRef, depth = 0) {
  switch (typeof v) {
    case 'undefined': w.room(1); w.buf[w.n++] = 0xf7; return;
    case 'boolean': w.room(1); w.buf[w.n++] = v ? 0xf5 : 0xf4; return;
    case 'number':
      if (Number.isSafeInteger(v)) return v >= 0 ? w.head(0, v) : w.head(1, -1 - v);
      w.room(9); w.buf[w.n++] = 0xfb; w.dv.setFloat64(w.n, v); w.n += 8; return;
    case 'bigint':
      if (v >= 0n && v < 1n << 64n) return w.head(0, v < 1n << 53n ? Number(v) : v);
      if (v < 0n && v >= -(1n << 64n)) { const a = -1n - v; return w.head(1, a < 1n << 53n ? Number(a) : a); }
      throw new RangeError('BigInt outside 64 bits');
    case 'string': return w.text(v);
  }
  if (v === null) { w.room(1); w.buf[w.n++] = 0xf6; return; }
  if (depth >= MAX_DEPTH) throw new RangeError('value too deep');
  if (v instanceof Uint8Array) return w.bytes(v);
  if (v instanceof ArrayBuffer) return w.bytes(new Uint8Array(v));
  if (ArrayBuffer.isView(v)) return w.bytes(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
  if (Array.isArray(v)) { w.head(4, v.length); for (let i = 0; i < v.length; i++) put(w, v[i], toRef, depth + 1); return; }
  if (v instanceof Date) return put(w, v.getTime(), toRef, depth);
  if (v instanceof Error) { generic(w, 3); w.text('Error'); w.text(v.name); w.text(v.message); return; }
  const proto = Object.getPrototypeOf(v);
  if (proto === Object.prototype || proto === null) {
    const keys = Object.keys(v); w.head(5, keys.length);
    for (let i = 0; i < keys.length; i++) { w.key(keys[i]); put(w, v[keys[i]], toRef, depth + 1); }
    return;
  }
  generic(w, 2); w.text('Ref'); w.head(0, toRef(v));
}

function generic(w, items) { w.room(2); w.buf[w.n++] = 0xd8; w.buf[w.n++] = 27; w.head(4, items); }

export function encode(v, toRef = () => { throw new Error('no ref table'); }) { const w = new Writer(); put(w, v, toRef); return w.done(); }

export function decode(u8, fromRef = () => { throw new Error('no ref table'); }) {
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  let at = 0;
  const bad = (why) => { throw new Error(`bad CBOR at ${at}: ${why}`); };
  const arg = (info) => {
    if (info < 24) return info;
    let x;
    switch (info) {
      case 24: x = u8[at]; at += 1; return x;
      case 25: x = dv.getUint16(at); at += 2; return x;
      case 26: x = dv.getUint32(at); at += 4; return x;
      case 27: { const b = dv.getBigUint64(at); at += 8; return b < 1n << 53n ? Number(b) : b; }
      default: bad('indefinite or reserved length');
    }
  };
  // Key i of a map is often key i of the map before it (rows of one query): compare the bytes
  // with the last key at that place, and reuse its string.
  const lastKey = [];
  const key = (i, depth) => {
    const ib = u8[at];
    if (ib >> 5 === 3 && (ib & 31) < 24) {
      const n = ib & 31, last = lastKey[i];
      if (last !== undefined && last.n === n) {
        let same = true;
        for (let j = 0; j < n; j++) if (u8[at + 1 + j] !== u8[last.at + j]) { same = false; break; }
        if (same) { at += 1 + n; return last.s; }
      }
      const start = at + 1, s = take(depth + 1);
      if (i < 64) lastKey[i] = { n, at: start, s };
      return s;
    }
    const k = take(depth + 1);
    if (typeof k !== 'string') bad('key');
    return k;
  };
  const take = (depth) => {
    if (at >= u8.length) bad('end of input');
    if (depth > MAX_DEPTH) bad('too deep');
    const ib = u8[at++], major = ib >> 5, info = ib & 31;
    if (major === 7) {
      switch (info) {
        case 20: return false;
        case 21: return true;
        case 22: return null;
        case 23: return undefined;
        case 25: { const h = dv.getUint16(at); at += 2; return half(h); }
        case 26: { const f = dv.getFloat32(at); at += 4; return f; }
        case 27: { const f = dv.getFloat64(at); at += 8; return f; }
        default: bad('simple value');
      }
    }
    const n = arg(info);
    switch (major) {
      case 0: return n;
      case 1: return typeof n === 'bigint' ? -1n - n : -1 - n;
      case 2: { const b = u8.slice(at, at + n); at += n; return b; }
      case 3: { const s = n < 16 ? shortText(u8, at, n) : fromUtf8.decode(u8.subarray(at, at + n)); at += n; return s; }
      case 4: { const a = new Array(n); for (let i = 0; i < n; i++) a[i] = take(depth + 1); return a; }
      case 5: { const o = {}; for (let i = 0; i < n; i++) { const k = key(i, depth); o[k] = take(depth + 1); } return o; }
      case 6: {
        if (n !== 27) bad(`tag ${n}`);
        const g = take(depth + 1);
        if (g[0] === 'Ref') return fromRef(g[1]);
        if (g[0] === 'Error') { const e = new Error(g[2]); e.name = g[1]; return e; }
        bad('generic object');
      }
    }
  };
  const v = take(0);
  if (at !== u8.length) bad('trailing bytes');
  return v;
}

function half(h) {
  const exp = (h >> 10) & 0x1f, mant = h & 0x3ff;
  const v = exp === 0 ? mant * 2 ** -24 : exp !== 31 ? (mant + 1024) * 2 ** (exp - 25) : mant === 0 ? Infinity : NaN;
  return h & 0x8000 ? -v : v;
}
