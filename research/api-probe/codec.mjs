// JS side of the bridge codec (API.md 5). Same byte format as Js.roc.
const enc = new TextEncoder();
const dec = new TextDecoder('utf-8', { fatal: true });

export class Writer {
  constructor() { this.buf = new Uint8Array(1024); this.dv = new DataView(this.buf.buffer); this.n = 0; }
  room(k) {
    if (this.n + k <= this.buf.length) return;
    const b = new Uint8Array(Math.max(this.buf.length * 2, this.n + k));
    b.set(this.buf.subarray(0, this.n)); this.buf = b; this.dv = new DataView(b.buffer);
  }
  u8(x) { this.room(1); this.buf[this.n++] = x; }
  u32(x) { this.room(4); this.dv.setUint32(this.n, x, true); this.n += 4; }
  bytes(b) { this.u32(b.length); this.room(b.length); this.buf.set(b, this.n); this.n += b.length; }
  text(s) {
    this.room(4 + s.length * 3);
    // ASCII fast path: short strings are most of the keys and values.
    if (s.length <= 64) {
      const b = this.buf, start = this.n + 4;
      let i = 0;
      for (; i < s.length; i++) { const c = s.charCodeAt(i); if (c > 0x7f) break; b[start + i] = c; }
      if (i === s.length) { this.dv.setUint32(this.n, i, true); this.n = start + i; return; }
    }
    const r = enc.encodeInto(s, this.buf.subarray(this.n + 4)); this.dv.setUint32(this.n, r.written, true); this.n += 4 + r.written;
  }
  done() { return this.buf.subarray(0, this.n); }
}

// toRef(obj) -> id: values that are not plain data stay in JS as a handle.
export function put(w, v, toRef) {
  switch (typeof v) {
    case 'undefined': return w.u8(0);
    case 'boolean': return w.u8(v ? 3 : 2);
    case 'number': w.u8(4); w.room(8); w.dv.setFloat64(w.n, v, true); w.n += 8; return;
    case 'bigint': w.u8(5); w.room(8); w.dv.setBigInt64(w.n, BigInt.asIntN(64, v), true); w.n += 8; return;
    case 'string': w.u8(6); return w.text(v);
  }
  if (v === null) return w.u8(1);
  if (v instanceof Uint8Array) { w.u8(7); return w.bytes(v); }
  if (v instanceof ArrayBuffer) { w.u8(7); return w.bytes(new Uint8Array(v)); }
  if (Array.isArray(v)) { w.u8(8); w.u32(v.length); for (const x of v) put(w, x, toRef); return; }
  if (v instanceof Error) { w.u8(11); w.text(v.name); return w.text(v.message); }
  const proto = Object.getPrototypeOf(v);
  if (typeof v.$ref === 'number') { w.u8(10); return w.u32(v.$ref); }
  if (proto === Object.prototype || proto === null) {
    const keys = Object.keys(v); w.u8(9); w.u32(keys.length);
    for (const k of keys) { w.text(k); put(w, v[k], toRef); }
    return;
  }
  w.u8(10); w.u32(toRef(v));
}

export function encode(v, toRef = () => { throw new Error('no ref table'); }) { const w = new Writer(); put(w, v, toRef); return w.done(); }

export function decode(u8, fromRef = () => { throw new Error('no ref table'); }) {
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  let at = 0;
  const u32 = () => { const x = dv.getUint32(at, true); at += 4; return x; };
  const bytes = () => { const n = u32(); const b = u8.subarray(at, at + n); at += n; return b; };
  const text = () => dec.decode(bytes());
  const take = () => {
    const t = u8[at++];
    switch (t) {
      case 0: return undefined;
      case 1: return null;
      case 2: return false;
      case 3: return true;
      case 4: { const x = dv.getFloat64(at, true); at += 8; return x; }
      case 5: { const x = dv.getBigInt64(at, true); at += 8; return x; }
      case 6: return text();
      case 7: return bytes().slice();
      case 8: { const n = u32(); const a = new Array(n); for (let i = 0; i < n; i++) a[i] = take(); return a; }
      case 9: { const n = u32(); const o = {}; for (let i = 0; i < n; i++) { const k = text(); o[k] = take(); } return o; }
      case 10: return fromRef(u32());
      case 11: { const name = text(); const e = new Error(text()); e.name = name; return e; }
      default: throw new Error(`bad tag ${t} at ${at - 1}`);
    }
  };
  const v = take();
  if (at !== u8.length) throw new Error(`trailing bytes at ${at}`);
  return v;
}
