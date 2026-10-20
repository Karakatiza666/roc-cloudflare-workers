// The CBOR profile of API.md 5 (RFC 8949): a writer and a reader, with no JS value rules (see values.js).
//
// Profile. Definite lengths only. The reader takes any width of an argument (also f16 and f32).
// The writer takes the shortest width for each argument, also for the head of an array and of a map
// (JS knows the count first). Floats are always f64. Tags: 27 (a Ref or an Error) and 24 (Packed).
// Reserved values (28 to 30), indefinite lengths, other tags and other simple values are errors.
// Depth: 64 containers or less, both ways. Text must be valid UTF-8. Bytes after the value are an error.
//
// Tag 4 (a decimal fraction, RFC 8949 3.4.4, the encoding of a Dec of Roc that has a fraction): [exponent, mantissa],
// the mantissa an integer or a bignum (tags 2 and 3, only inside tag 4). The reader gives the plain object
// `{ $dec: [exponent, mantissa] }` (exponent: a Number, mantissa: a Number, or a BigInt of 2^53 or more) and the
// writer turns such an object back into the same tag 4. The value stays exact: a Roc to Roc RPC goes decode, structured
// clone (it keeps a plain object, but not a class instance), encode. JS turns it into a Number with `decNumber` only
// where it must use the value (an SQL parameter, a JSON message): see `plain`.
//
// Errors: a TypeError for a format fault (not in the profile, bad UTF-8, trailing bytes), a RangeError
// for a limit (cut input, depth, size). The shim maps both to status 1.

export const MAX_DEPTH = 64;

// The key of the plain object that stands for a tag 4 value.
export const DEC_KEY = '$dec';
const isInt = (x) => (typeof x === 'number' && Number.isSafeInteger(x)) || typeof x === 'bigint';
// A tag 4 value: an object with the one key `$dec`, the array [exponent (a safe integer Number), mantissa (an integer)].
export function isDec(v) {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return false;
  const k = Object.keys(v);
  if (k.length !== 1 || k[0] !== DEC_KEY) return false;
  const d = v[DEC_KEY];
  return Array.isArray(d) && d.length === 2 && typeof d[0] === 'number' && Number.isSafeInteger(d[0]) && isInt(d[1]);
}
// The Number of a tag 4 value: mantissa * 10^exponent, rounded to the nearest double.
export const decNumber = (d) => Number(`${d[DEC_KEY][1]}e${d[DEC_KEY][0]}`);
// A copy of `v` with each tag 4 value as a Number (for a JSON message). Other values stay as they are.
export function plain(v, level = 0) {
  if (isDec(v)) return decNumber(v);
  if (v === null || typeof v !== 'object') return v;
  if (level >= MAX_DEPTH) throw depthError();
  if (Array.isArray(v)) return v.map((x) => plain(x, level + 1));
  const proto = Object.getPrototypeOf(v);
  if (proto !== Object.prototype && proto !== null) return v;
  const o = {};
  for (const k of Object.keys(v)) Object.defineProperty(o, k, { value: plain(v[k], level + 1), enumerable: true, writable: true, configurable: true });
  return o;
}

// A write over the size limit (`maxBytes`). Callers map it by `e.name === 'TooLarge'`.
export class TooLarge extends RangeError {
  constructor(message) { super(message); this.name = 'TooLarge'; }
}
// A caller buffer with no `grow` is full.
export class BufferFull extends RangeError {
  constructor(message) { super(message); this.name = 'BufferFull'; }
}

export const depthError = () => new RangeError(`CBOR: value is deeper than ${MAX_DEPTH} levels, or has a cycle`);

const utf8 = new TextEncoder();
// ignoreBOM: true keeps a U+FEFF at the start of a text. The default drops it.
const fromUtf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

// The bytes of short object keys, shared by all writers: the rows of one query have the same keys.
const keyBytes = new Map();

export class Writer {
  // init: a byte count (the writer owns a growable buffer), or a Uint8Array of the caller.
  // opts.grow(min, old, used): gives a bigger Uint8Array of `min` bytes or more. The writer copies the `used` bytes
  //   into it after the call, so `grow` must not free `old` (free it after done()), unless `copies`. With a caller buffer
  //   and no `grow`, a full buffer is a BufferFull. For a buffer in wasm memory, `grow` makes the new view.
  // opts.copies: `grow` has copied the used bytes itself (a buffer in wasm memory: a `js_alloc` can detach the old view).
  // opts.maxBytes: the limit of the output size: more is a TooLarge.
  // Free space: text needs 3 bytes for each UTF-16 unit while it is written, so keep room or give `grow`.
  constructor(init = 1024, opts = {}) {
    this.use(typeof init === 'number' ? new Uint8Array(init) : init);
    this.grow = opts.grow ?? (typeof init === 'number' ? (min, old) => new Uint8Array(Math.max(old.length * 2, min)) : null);
    this.copies = opts.copies ?? false;
    this.limit = opts.maxBytes ?? Infinity;
    this.n = 0;
  }
  use(buf) { this.buf = buf; this.dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength); }
  reset() { this.n = 0; }
  room(k) {
    if (this.n + k > this.buf.length) this.expand(this.n + k);
  }
  expand(min) {
    if (this.grow === null) throw new BufferFull(`CBOR: output buffer of ${this.buf.length} bytes is full`);
    const b = this.grow(min, this.buf, this.n);
    if (!(b instanceof Uint8Array) || b.length < min) throw new RangeError(`CBOR: grow gave less than ${min} bytes`);
    if (!this.copies) b.set(this.buf.subarray(0, this.n));
    this.use(b);
  }
  over() { throw new TooLarge(`CBOR: output is larger than ${this.limit} bytes`); }
  // Writes a head at `at` (the room is there) and gives the next offset. x: a Number from 0 to 2^53.
  // A BigInt has its own path (head64): a head with Numbers only keeps its type feedback, and its speed.
  headAt(at, major, x) {
    const m = major << 5, b = this.buf;
    if (x < 24) { b[at] = m | x; return at + 1; }
    if (x < 0x100) { b[at] = m | 24; b[at + 1] = x; return at + 2; }
    if (x < 0x10000) { b[at] = m | 25; this.dv.setUint16(at + 1, x); return at + 3; }
    if (x < 0x100000000) { b[at] = m | 26; this.dv.setUint32(at + 1, x); return at + 5; }
    b[at] = m | 27;
    this.dv.setUint32(at + 1, Math.floor(x / 4294967296)); this.dv.setUint32(at + 5, x >>> 0);
    return at + 9;
  }
  head64(major, big) {
    this.room(9);
    this.buf[this.n] = (major << 5) | 27;
    this.dv.setBigUint64(this.n + 1, big);
    this.n += 9;
    if (this.n > this.limit) this.over();
  }
  head(major, x) {
    this.room(9);
    this.n = this.headAt(this.n, major, x);
    if (this.n > this.limit) this.over();
  }
  array(count) { this.head(4, count); }
  map(count) { this.head(5, count); }
  tag(t) { this.head(6, t); }
  undef() { this.room(1); this.buf[this.n++] = 0xf7; }
  null() { this.room(1); this.buf[this.n++] = 0xf6; }
  bool(b) { this.room(1); this.buf[this.n++] = b ? 0xf5 : 0xf4; }
  float(x) { this.room(9); this.buf[this.n++] = 0xfb; this.dv.setFloat64(this.n, x); this.n += 8; if (this.n > this.limit) this.over(); }
  // A safe-integer Number.
  int(v) { if (v >= 0) this.head(0, v); else this.head(1, -1 - v); }
  // A BigInt from -2^64 to 2^64 - 1 (the range of the major types 0 and 1). The caller checks its own range.
  bigint(v) {
    const major = v >= 0n ? 0 : 1, a = v >= 0n ? v : -1n - v;
    if (a < 0x20000000000000n) this.head(major, Number(a)); else this.head64(major, a);
  }
  // The tag 4 value of `{ $dec: [exponent, mantissa] }` (the caller checks it with isDec). A mantissa out of the range of the
  // major types 0 and 1 is a bignum (tag 2 or 3).
  dec(d) {
    const [exp, mant] = d[DEC_KEY];
    this.tag(4); this.array(2); this.int(exp);
    if (typeof mant === 'number') return this.int(mant);
    if (mant >= -(1n << 64n) && mant < (1n << 64n)) return this.bigint(mant);
    const a = mant >= 0n ? mant : -1n - mant;
    let hex = a.toString(16);
    if (hex.length % 2) hex = '0' + hex;
    const u8 = new Uint8Array(hex.length / 2);
    for (let i = 0; i < u8.length; i++) u8[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
    this.tag(mant >= 0n ? 2 : 3);
    this.bytes(u8);
  }
  // Bytes that are already CBOR (a prefix of a tag, for example).
  raw(u8) { this.room(u8.length); this.buf.set(u8, this.n); this.n += u8.length; }
  text(s) {
    const len = s.length;
    // ASCII fast path for short text (48 was the fastest of 8, 24, 48, 128 for D1 rows).
    if (len < 48) {
      this.room(2 + len);
      const b = this.buf, h = len < 24 ? 1 : 2, start = this.n + h;
      let i = 0;
      for (; i < len; i++) { const c = s.charCodeAt(i); if (c > 0x7f) break; b[start + i] = c; }
      if (i === len) {
        if (h === 1) b[this.n] = 0x60 | len; else { b[this.n] = 0x78; b[this.n + 1] = len; }
        this.n = start + len;
        if (this.n > this.limit) this.over();
        return;
      }
    }
    // Reserve the head for the largest size, encode, then move the bytes if the head is smaller.
    const max = len * 3, hmax = max < 24 ? 1 : max < 0x100 ? 2 : max < 0x10000 ? 3 : 5;
    this.room(hmax + max);
    const w = utf8.encodeInto(s, this.buf.subarray(this.n + hmax)).written;
    const h = w < 24 ? 1 : w < 0x100 ? 2 : w < 0x10000 ? 3 : 5;
    if (h !== hmax) this.buf.copyWithin(this.n + h, this.n + hmax, this.n + hmax + w);
    this.n = this.headAt(this.n, 3, w) + w;
    if (this.n > this.limit) this.over();
  }
  // An object key. The bytes of short keys are cached. A full cache is cleared (a cache of other keys must not slow the next rows).
  key(k) {
    const b = keyBytes.get(k);
    if (b !== undefined) this.raw(b);
    else {
      const start = this.n;
      this.text(k);
      if (k.length < 64) {
        if (keyBytes.size >= 256) keyBytes.clear();
        keyBytes.set(k, this.buf.slice(start, this.n));
      }
      return;
    }
    if (this.n > this.limit) this.over();
  }
  bytes(u8) {
    if (this.n + u8.length > this.limit) this.over();
    this.head(2, u8.length);
    this.raw(u8);
  }
  // A byte string of which the content is written by `fn` (tag 24 data). The size limit of the content is
  // `maxBytes`. The head has the shortest width: the content moves down when the head is long.
  packed(maxBytes, fn) {
    this.room(1);
    this.buf[this.n++] = 0x40;
    const start = this.n, saved = this.limit;
    this.limit = Math.min(saved, start + maxBytes);
    try { fn(); } finally { this.limit = saved; }
    const len = this.n - start;
    if (start + len > start + maxBytes) throw new TooLarge(`CBOR: packed value is larger than ${maxBytes} bytes`);
    const h = len < 24 ? 1 : len < 0x100 ? 2 : len < 0x10000 ? 3 : len < 0x100000000 ? 5 : 9;
    if (h > 1) {
      this.room(h - 1);
      this.buf.copyWithin(start + h - 1, start, start + len);
      this.n += h - 1;
    }
    this.headAt(start - 1, 2, len);
    if (this.n > this.limit) this.over();
  }
  // The bytes written. A view of the buffer: it is valid until the next write. Use .slice() to keep it.
  done() {
    if (this.n > this.limit) this.over();
    return this.buf.subarray(0, this.n);
  }
}

// Short ASCII text without TextDecoder, which costs much for each call.
function shortText(u8, at, n) {
  let s = '';
  for (let i = at; i < at + n; i++) { const c = u8[i]; if (c > 0x7f) return null; s += String.fromCharCode(c); }
  return s;
}

function half(h) {
  const exp = (h >> 10) & 0x1f, mant = h & 0x3ff;
  const v = exp === 0 ? mant * 2 ** -24 : exp !== 31 ? (mant + 1024) * 2 ** (exp - 25) : mant === 0 ? Infinity : NaN;
  return h & 0x8000 ? -v : v;
}

class Reader {
  constructor(u8, ref, base) {
    this.u8 = u8; this.dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    this.at = 0; this.ref = ref; this.base = base;
    // Key i of a map is often key i of the map before it (rows of one query): compare the bytes
    // with the last key at that place, and reuse its string.
    this.lastKey = [];
  }
  fail(why) { throw new TypeError(`CBOR: ${why} at byte ${this.base + this.at}`); }
  need(n) {
    if (n > this.u8.length - this.at) throw new RangeError(`CBOR: input ends at byte ${this.base + this.u8.length}, but byte ${this.base + this.at} needs ${n} more`);
  }
  // The argument of a head: a Number up to 2^53, else a BigInt.
  arg(info) {
    if (info < 24) return info;
    const u8 = this.u8, dv = this.dv;
    switch (info) {
      case 24: this.need(1); return u8[this.at++];
      case 25: { this.need(2); const x = dv.getUint16(this.at); this.at += 2; return x; }
      case 26: { this.need(4); const x = dv.getUint32(this.at); this.at += 4; return x; }
      case 27: {
        this.need(8);
        const hi = dv.getUint32(this.at), lo = dv.getUint32(this.at + 4);
        this.at += 8;
        if (hi < 0x200000 || (hi === 0x200000 && lo === 0)) return hi * 4294967296 + lo;
        return (BigInt(hi) << 32n) | BigInt(lo);
      }
      case 31: this.fail('indefinite length (or break) is not in the profile');
      default: this.fail(`reserved additional information ${info}`);
    }
  }
  // A count or a size: it must fit in the rest of the input (`each` bytes at least for each unit).
  len(info, each) {
    const n = this.arg(info);
    if (typeof n !== 'number' || n * each > this.u8.length - this.at) {
      throw new RangeError(`CBOR: length ${n} at byte ${this.base + this.at} is longer than the input`);
    }
    return n;
  }
  str(n) {
    const at = this.at;
    let s = n < 16 ? shortText(this.u8, at, n) : null;
    if (s === null) {
      try { s = fromUtf8.decode(this.u8.subarray(at, at + n)); } catch { this.fail('text is not valid UTF-8'); }
    }
    this.at = at + n;
    return s;
  }
  // A text item (a map key, a part of tag 27).
  text(i, what) {
    this.need(1);
    const ib = this.u8[this.at];
    if (ib >> 5 !== 3) this.fail(`${what} must be text`);
    this.at++;
    if (i !== undefined && (ib & 31) < 24) return this.key(i, ib & 31);
    return this.str(this.len(ib & 31, 1));
  }
  key(i, n) {
    const u8 = this.u8, last = this.lastKey[i];
    this.need(n);
    if (last !== undefined && last.n === n) {
      let same = true;
      for (let j = 0; j < n; j++) if (u8[this.at + j] !== u8[last.at + j]) { same = false; break; }
      if (same) { this.at += n; return last.s; }
    }
    const start = this.at, s = this.str(n);
    if (i < 64) this.lastKey[i] = { n, at: start, s };
    return s;
  }
  value(level) {
    this.need(1);
    const ib = this.u8[this.at++], major = ib >> 5, info = ib & 31;
    switch (major) {
      case 0: return this.arg(info);
      case 1: {
        const n = this.arg(info);
        return typeof n === 'number' && n < 0x20000000000000 ? -1 - n : -1n - BigInt(n);
      }
      case 2: {
        const n = this.len(info, 1), b = new Uint8Array(n);
        b.set(this.u8.subarray(this.at, this.at + n)); this.at += n;
        return b;
      }
      case 3: return this.str(this.len(info, 1));
      case 4: {
        if (level >= MAX_DEPTH) throw depthError();
        const n = this.len(info, 1), a = new Array(n);
        for (let i = 0; i < n; i++) a[i] = this.value(level + 1);
        return a;
      }
      case 5: {
        if (level >= MAX_DEPTH) throw depthError();
        const n = this.len(info, 2), o = {};
        for (let i = 0; i < n; i++) {
          const k = this.text(i, 'a map key');
          // `o.__proto__ = x` would set the prototype: define the property.
          if (k === '__proto__') Object.defineProperty(o, k, { value: this.value(level + 1), enumerable: true, writable: true, configurable: true });
          else o[k] = this.value(level + 1);
        }
        return o;
      }
      case 6: {
        const t = this.arg(info);
        if (t === 27) return this.generic();
        if (t === 24) return this.packed(level);
        if (t === 4) return this.decimal(level);
        return this.fail(`tag ${t} is not in the profile`);
      }
      default: return this.simple(info);
    }
  }
  simple(info) {
    switch (info) {
      case 20: return false;
      case 21: return true;
      case 22: return null;
      case 23: return undefined;
      case 25: { this.need(2); const h = this.dv.getUint16(this.at); this.at += 2; return half(h); }
      case 26: { this.need(4); const f = this.dv.getFloat32(this.at); this.at += 4; return f; }
      case 27: { this.need(8); const f = this.dv.getFloat64(this.at); this.at += 8; return f; }
      case 31: return this.fail('indefinite length (or break) is not in the profile');
      case 28: case 29: case 30: return this.fail(`reserved additional information ${info}`);
      default: return this.fail(`simple value ${info} is not in the profile`);
    }
  }
  // Tag 27: ["Ref", id] or ["Error", name, message].
  generic() {
    this.need(1);
    const ib = this.u8[this.at++];
    if (ib >> 5 !== 4) this.fail('tag 27 needs an array');
    const n = this.arg(ib & 31), kind = this.text(undefined, 'the kind of tag 27');
    if (kind === 'Ref' && n === 2) {
      this.need(1);
      const jb = this.u8[this.at++];
      const id = jb >> 5 === 0 ? this.arg(jb & 31) : -1;
      if (typeof id !== 'number' || id > 0xffffffff || id < 0) this.fail('the id of a Ref must be an unsigned 32 bit integer');
      if (this.ref === undefined) this.fail('a Ref needs a ref table');
      return this.ref(id);
    }
    if (kind === 'Error' && n === 3) {
      const name = this.text(undefined, 'the name of an Error'), e = new Error(this.text(undefined, 'the message of an Error'));
      e.name = name;
      return e;
    }
    return this.fail('tag 27 is not ["Ref", id] or ["Error", name, message]');
  }
  // Tag 4: [exponent, mantissa] (the head of tag 4 is read). Gives { $dec: [exponent, mantissa] }.
  decimal(level) {
    if (level >= MAX_DEPTH) throw depthError();
    this.need(1);
    if (this.u8[this.at++] !== 0x82) this.fail('tag 4 needs an array of 2 items');
    const exp = this.int('the exponent of tag 4');
    if (typeof exp !== 'number') this.fail('the exponent of tag 4 is too large');
    this.need(1);
    const ib = this.u8[this.at];
    let mant;
    if (ib >> 5 === 6) {
      this.at++;
      const t = this.arg(ib & 31);
      if (t !== 2 && t !== 3) this.fail(`tag ${t} is not in the profile (the mantissa of tag 4 is an integer or tag 2 or 3)`);
      this.need(1);
      const bb = this.u8[this.at++];
      if (bb >> 5 !== 2) this.fail(`tag ${t} needs a byte string`);
      const n = this.len(bb & 31, 1);
      let big = 0n;
      for (let i = 0; i < n; i++) big = (big << 8n) | BigInt(this.u8[this.at + i]);
      this.at += n;
      mant = t === 2 ? big : -1n - big;
      if (mant >= -0x1fffffffffffffn && mant <= 0x1fffffffffffffn) mant = Number(mant);
    } else {
      mant = this.int('the mantissa of tag 4');
    }
    return { [DEC_KEY]: [exp, mant] };
  }
  // An integer item (major type 0 or 1): a Number, or a BigInt of 2^53 or more.
  int(what) {
    this.need(1);
    const ib = this.u8[this.at++], major = ib >> 5;
    if (major > 1) this.fail(`${what} must be an integer`);
    const n = this.arg(ib & 31);
    if (major === 0) return n;
    return typeof n === 'number' && n < 0x20000000000000 ? -1 - n : -1n - BigInt(n);
  }
  // Tag 24: a byte string with one CBOR item. It reads as that item.
  packed(level) {
    this.need(1);
    const ib = this.u8[this.at++];
    if (ib >> 5 !== 2) this.fail('tag 24 needs a byte string');
    const n = this.len(ib & 31, 1);
    const r = new Reader(this.u8.subarray(this.at, this.at + n), this.ref, this.base + this.at);
    const v = r.value(level);
    if (r.at !== n) r.fail('bytes after the value inside tag 24');
    this.at += n;
    return v;
  }
}

// Reads one value. opts.ref(id) gives the object of a Ref (tag 27). `u8` is a Uint8Array.
export function decode(u8, opts = {}) {
  if (!(u8 instanceof Uint8Array)) throw new TypeError('CBOR: decode needs a Uint8Array');
  const r = new Reader(u8, opts.ref, 0);
  const v = r.value(0);
  if (r.at !== u8.length) r.fail('bytes after the value');
  return v;
}
