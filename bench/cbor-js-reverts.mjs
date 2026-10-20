// node bench/cbor-js-reverts.mjs [name-filter]
// Revert checks for bench/cbor-js-test.mjs: it copies js/ to .cache/cbor-reverts/, breaks one rule in the copy,
// runs the test, and checks that the test that must catch it fails. The files in js/ are not changed.
// A change that finds no text to replace is an error (the code moved: update this list).
// Exit 1 when the clean copy fails, a revert is not caught, or a revert breaks the test run.
import { cpSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const work = `${root}.cache/cbor-reverts`;

// [from, to, all]: replace the text `from` (all places when `all`).
const R = (file, name, expect, ...edits) => ({ file, name, expect, edits });
const C = 'js/cbor.js', V = 'js/values.js';
const mutations = [
  R(C, 'shortest width off (x < 24 takes 2 bytes)', /RFC 8949 A: encode|shortest width/, ['if (x < 24) { b[at] = m | x;', 'if (false) { b[at] = m | x;']),
  R(C, 'array head always 5 bytes', /shortest width/, ['array(count) { this.head(4, count); }', 'array(count) { this.room(9); this.buf[this.n] = 0x9a; this.dv.setUint32(this.n + 1, count); this.n += 5; }']),
  R(C, 'text head does not move down', /shortest width/, ['if (h !== hmax) this.buf.copyWithin(this.n + h, this.n + hmax, this.n + hmax + w);', '']),
  R(C, 'negative integer as -v (not -1 - v)', /RFC 8949 A: encode/, ['else this.head(1, -1 - v);', 'else this.head(1, -v);']),
  R(C, 'BigInt negative as -v', /integers: 2\^53/, ['-1n - v;', '-v;']),
  R(C, 'decoder: depth limit off', /J3 depth: 64 levels/, ['if (level >= MAX_DEPTH) throw depthError();', '', true]),
  R(V, 'encoder: depth limit off', /J3 depth/, ['if (level >= MAX_DEPTH) throw depthError();', '', true]),
  R(C, 'decoder: f16 off', /decode of the vectors/, ['return half(h); }', "return this.fail('f16'); }"]),
  R(C, 'decoder: f32 off', /decode of the vectors/, ['this.at += 4; return f; }', "this.at += 4; return this.fail('f32'); }"]),
  R(C, 'decoder: trailing bytes allowed', /bytes after the value/, ["if (r.at !== u8.length) r.fail('bytes after the value');", '']),
  R(C, 'decoder: bytes after the item in tag 24 allowed', /Packed: a Packed inside|bytes after the value/, ["if (r.at !== n) r.fail('bytes after the value inside tag 24');", '']),
  R(C, 'decoder: UTF-8 not fatal', /valid UTF-8/, ["{ fatal: true, ignoreBOM: true }", "{ fatal: false, ignoreBOM: true }"]),
  R(C, 'decoder: U+FEFF dropped', /U\+FEFF/, ["{ fatal: true, ignoreBOM: true }", "{ fatal: true, ignoreBOM: false }"]),
  R(C, 'decoder: no check for a cut input', /cut input/, ['if (n > this.u8.length - this.at) throw', 'if (false) throw']),
  R(C, 'decoder: no check of a length against the input', /length past the input/, ['n * each > this.u8.length - this.at', 'false']),
  R(C, 'decoder: any tag is read', /not in the profile is an error/, ['return this.fail(`tag ${t} is not in the profile`);', 'return this.value(level);']),
  R(C, 'decoder: tag 24 off', /decode of the vectors/, ['if (t === 24) return this.packed(level);', '']),
  R(C, 'decoder: indefinite length read as 0', /indefinite lengths/, ["case 31: this.fail('indefinite length (or break) is not in the profile');", 'case 31: return 0;']),
  R(C, 'decoder: reserved 28 to 30 read as 0 (majors 0 to 6)', /reserved values 28 to 30/, ['default: this.fail(`reserved additional information ${info}`);', 'default: return 0;']),
  R(C, 'decoder: reserved 28 to 30 as a simple value (major 7)', /reserved values 28 to 30/, ['case 28: case 29: case 30: return this.fail(`reserved additional information ${info}`);', 'case 28: case 29: case 30: return null;']),
  R(C, 'decoder: simple values 0 to 19 read', /not in the profile is an error/, ['default: return this.fail(`simple value ${info} is not in the profile`);', 'default: return null;']),
  R(C, 'decoder: Number up to 2^54', /Int in, Number or BigInt out/, ['hi < 0x200000 || (hi === 0x200000 && lo === 0)', 'hi < 0x400000']),
  R(C, 'decoder: negative Number up to -2^54', /Int in, Number or BigInt out/, ['n < 0x20000000000000 ? -1 - n', 'n < 0x40000000000000 ? -1 - n']),
  R(C, 'decoder: __proto__ key sets the prototype', /__proto__/, ["if (k === '__proto__')", 'if (false)']),
  R(C, 'decoder: key cache compares nothing', /key cache/, ['if (u8[this.at + j] !== u8[last.at + j]) { same = false; break; }', '']),
  R(C, 'decoder: tag 27 "Ref" with any count', /tag 27: only/, ["kind === 'Ref' && n === 2", "kind === 'Ref'"]),
  R(C, 'decoder: Ref id above u32', /tag 27: only/, ['|| id > 0xffffffff || id < 0', '|| id < 0']),
  R(C, 'decoder: Error name not set', /J6/, ['      e.name = name;\n', '']),
  R(C, 'decoder: Bytes is a view of the input', /J2/, ['const n = this.len(info, 1), b = new Uint8Array(n);\n        b.set(this.u8.subarray(this.at, this.at + n)); this.at += n;', 'const n = this.len(info, 1), b = this.u8.subarray(this.at, this.at + n); this.at += n;']),
  R(C, 'decoder: Packed starts at depth 0', /J3 depth: a cycle/, ['const v = r.value(level);', 'const v = r.value(0);']),
  R(C, 'writer: TooLarge has no name', /Packed: maxBytes/, ["this.name = 'TooLarge';", '']),
  R(C, 'writer: no size limit in a Packed', /Packed: maxBytes/, ['this.limit = Math.min(saved, start + maxBytes);', 'this.limit = saved;'], ['if (start + len > start + maxBytes) throw', 'if (false) throw']),
  R(C, 'writer: no size limit of the whole output', /Writer: maxBytes/, ['if (this.n > this.limit) this.over();', '', true]),
  R(C, 'writer: Packed head not moved', /Packed: the head of the byte string|200 rows/, ['this.buf.copyWithin(start + h - 1, start, start + len);', '']),
  R(C, 'writer: short text writes its head with head() (the prototype way)', /small buffer that grows/, ['if (h === 1) b[this.n] = 0x60 | len; else { b[this.n] = 0x78; b[this.n + 1] = len; }\n        this.n = start + len;', 'this.head(3, len); this.n += len;']),
  R(C, 'writer: a caller buffer grows by itself', /caller buffer/, ['typeof init === \'number\' ? (min, old) => new Uint8Array(Math.max(old.length * 2, min)) : null', '(min, old) => new Uint8Array(Math.max(old.length * 2, min))']),
  R(C, 'writer: grow result not checked', /grow\(min, old\)/, ['!(b instanceof Uint8Array) || b.length < min', 'false']),
  R(V, 'refs: a new id for each ref', /same id/, ['let id = this.ids.get(obj);\n    if (id === undefined) {', 'let id;\n    if (true) {']),
  R(V, 'refs: an unknown id gives undefined', /RS1 a Ref gives back/, ['if (!Number.isInteger(id) || id < 1 || id >= this.objs.length) throw', 'if (false) throw']),
  R(V, 'refs: clear() keeps the ids', /RS1 a Ref gives back/, ['this.ids.clear(); this.objs.length = 1;', 'this.objs.length = 1;']),
  R(V, 'J1: a safe integer as f64', /RFC 8949 A: encode|J1 primitives/, ['Number.isSafeInteger(v) ? w.int(v) : w.float(v)', 'w.float(v)']),
  R(V, 'J1: BigInt above i64 allowed in a tree', /J1 BigInt/, ['v > (typed ? U64_MAX : I64_MAX)', 'v > U64_MAX']),
  R(V, 'J1: BigInt below -2^63 allowed', /J1 BigInt/, ['v < I64_MIN || ', '']),
  R(V, 'Packed: BigInt up to i64 only', /integers: 2\^53/, ['v > (typed ? U64_MAX : I64_MAX)', 'v > I64_MAX']),
  R(V, 'J2: ArrayBuffer is a Ref', /J2/, ['if (v instanceof ArrayBuffer) return w.bytes(new Uint8Array(v));', '']),
  R(V, 'J2: views are a Ref', /J2/, ['if (ArrayBuffer.isView(v)) return w.bytes(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));', '']),
  R(V, 'J2: a view starts at 0', /J2/, ['new Uint8Array(v.buffer, v.byteOffset, v.byteLength)', 'new Uint8Array(v.buffer)']),
  R(V, 'J3: an object with a null prototype is a Ref', /J3 Array, plain object/, ['proto === Object.prototype || proto === null', 'proto === Object.prototype']),
  R(V, 'J3: keys sorted', /J3 Array, plain object/, ['Object.keys(v);', 'Object.keys(v).sort();']),
  R(V, 'J4: a Date is a Ref', /J4/, ['if (v instanceof Date) return put(w, v.getTime(), refs, level, typed);', '']),
  R(V, 'J5: a Headers is a Ref', /J5/, ['v instanceof Map || isHeaders(v) || v instanceof URLSearchParams', 'v instanceof Map || v instanceof URLSearchParams']),
  R(V, 'J5: a URLSearchParams is a Ref', /J5/, ['v instanceof Map || isHeaders(v) || v instanceof URLSearchParams', 'v instanceof Map || isHeaders(v)']),
  R(V, 'J5: a Map is a Ref', /J5/, ['v instanceof Map || isHeaders(v) || v instanceof URLSearchParams', 'isHeaders(v) || v instanceof URLSearchParams']),
  R(V, 'J6: an Error is a Ref', /J6/, ['if (v instanceof Error || isDomException(v)) {', 'if (false) {']),
  R(V, 'J7: another object is an error, not a Ref', /J7/, ['  return ref(w, v, refs, typed);\n}\n\nfunction packed', "  throw new TypeError('no ref');\n}\n\nfunction packed"]),
  R(V, 'Packed: a Ref is allowed', /Packed: typed data has no Ref/, ['if (typed) throw new TypeError(`Packed data cannot hold a ${', 'if (false) throw new TypeError(`Packed data cannot hold a ${']),
  R(V, 'Packed: a nested Packed is allowed', /Packed: typed data has no Ref/, ["if (typed) throw new TypeError('Packed data cannot hold a Packed value');", '']),
  R(V, 'Packed: an Error is allowed', /Packed: typed data has no Ref/, ['if (typed) throw new TypeError(`Packed data cannot hold an Error', 'if (false) throw new TypeError(`Packed data cannot hold an Error']),
  R(C, 'writer: copies after a grow that copied', /Writer: a grow that copies/, ['if (!this.copies) b.set(', 'if (true) b.set(']),
  R(V, 'Kept: a plain value is written as itself', /Kept/, ['if (v instanceof Kept) return ref(w, v.value, refs, typed);', '']),
  R(V, 'Packed: the content starts at depth 0', /J3 depth: a cycle/, ['put(w, value, refs, level, true)', 'put(w, value, refs, 0, true)']),
  // roc-cbor 0.2.0: tag 4, the Dec marker (MODULES.md 1 "The Dec in JS"). Names start with "Dec" (a filter: `node bench/cbor-js-reverts.mjs Dec`).
  R(C, 'Dec decoder: tag 4 is not in the profile', /Dec decode: tag 4 gives/, ['if (t === 4) return this.decimal(level);', '']),
  R(C, 'Dec decoder: tag 2 and 3 are read outside tag 4', /Dec decode: tag 2 and 3 outside/, ['if (t === 4) return this.decimal(level);', 'if (t === 4) return this.decimal(level);\n        if (t === 2 || t === 3) return this.value(level);']),
  R(C, 'Dec decoder: no tag 2 or 3 inside tag 4', /Dec decode: tags 2 and 3 inside/, ['if (t !== 2 && t !== 3) this.fail(', 'if (true) this.fail(']),
  R(C, 'Dec decoder: a negative bignum (tag 3) reads as positive', /Dec decode: tags 2 and 3 inside/, ['mant = t === 2 ? big : -1n - big;', 'mant = big;']),
  R(C, 'Dec decoder: a small bignum stays a BigInt', /Dec decode: tags 2 and 3 inside/, ['if (mant >= -0x1fffffffffffffn && mant <= 0x1fffffffffffffn) mant = Number(mant);', '']),
  R(C, 'Dec decoder: a negative integer mantissa as -n', /Dec decode: tag 4 gives/, ['if (major === 0) return n;\n    return typeof n === \'number\' && n < 0x20000000000000 ? -1 - n', 'if (major === 0) return n;\n    return typeof n === \'number\' && n < 0x20000000000000 ? -n']),
  R(C, 'Dec decoder: no check of the array of 2 items', /Dec decode: a bad shape/, ["if (this.u8[this.at++] !== 0x82) this.fail('tag 4 needs an array of 2 items');", 'this.at++;']),
  R(C, 'Dec decoder: no check of the exponent size', /Dec decode: a bad shape/, ["if (typeof exp !== 'number') this.fail('the exponent of tag 4 is too large');", '']),
  R(C, 'Dec decoder: the mantissa may be any item', /Dec decode: a bad shape/, ["if (major > 1) this.fail(`${what} must be an integer`);", '']),
  R(C, 'Dec decoder: no check that a bignum has a byte string', /Dec decode: a bad shape/, ["if (bb >> 5 !== 2) this.fail(`tag ${t} needs a byte string`);", '']),
  R(C, 'Dec decoder: no depth check of tag 4', /Dec decode: tag 4 counts as one level/, ['decimal(level) {\n    if (level >= MAX_DEPTH) throw depthError();\n', 'decimal(level) {\n']),
  R(V, 'Dec encoder: the marker is a plain map', /Dec encode: the marker is byte-identical/, ['if (isDec(v)) return w.dec(v);', '']),
  R(C, 'Dec encoder: a negative bignum is written as tag 2', /Dec encode: the marker is byte-identical/, ['this.tag(mant >= 0n ? 2 : 3);', 'this.tag(2);']),
  R(C, 'Dec encoder: every BigInt mantissa is a bignum', /Dec encode: the marker is byte-identical/, ['if (mant >= -(1n << 64n) && mant < (1n << 64n)) return this.bigint(mant);', '']),
  R(C, 'Dec encoder: no even length of the bignum hex', /Dec encode: the marker is byte-identical/, ["if (hex.length % 2) hex = '0' + hex;", '']),
  R(C, 'Dec encoder: the exponent is written as a Number only (the tag 4 head)', /Dec encode: the marker is byte-identical/, ['this.tag(4); this.array(2); this.int(exp);', 'this.tag(4); this.array(1); this.int(exp);']),
  R(C, 'Dec isDec: more keys are a marker', /Dec encode: an object that is not a marker/, ['if (k.length !== 1 || k[0] !== DEC_KEY) return false;', 'if (k[0] !== DEC_KEY) return false;']),
  R(C, 'Dec isDec: a float exponent is a marker', /Dec encode: an object that is not a marker/, ["d.length === 2 && typeof d[0] === 'number' && Number.isSafeInteger(d[0]) && isInt(d[1])", "d.length === 2 && typeof d[0] === 'number' && isInt(d[1])"]),
  R(C, 'Dec isDec: a float mantissa is a marker', /Dec encode: an object that is not a marker/, ["(typeof x === 'number' && Number.isSafeInteger(x)) || typeof x === 'bigint'", "typeof x === 'number' || typeof x === 'bigint'"]),
  R(C, 'Dec decNumber: a product, not the text', /Dec decNumber/, ['Number(`${d[DEC_KEY][1]}e${d[DEC_KEY][0]}`)', 'Number(d[DEC_KEY][1]) * 10 ** d[DEC_KEY][0]']),
  R(C, 'Dec plain: a marker stays an object', /Dec plain: each marker/, ['if (isDec(v)) return decNumber(v);', '']),
  R(C, 'Dec plain: no depth limit', /Dec plain: the depth limit/, ['if (level >= MAX_DEPTH) throw depthError();\n  if (Array.isArray(v)) return v.map', 'if (Array.isArray(v)) return v.map']),
  R(C, 'Dec plain: a class instance or a Uint8Array is copied as an object', /Dec plain: each marker/, ['if (proto !== Object.prototype && proto !== null) return v;', '']),
  R(C, 'Dec plain: a key __proto__ sets the prototype', /Dec plain: each marker/, ["Object.defineProperty(o, k, { value: plain(v[k], level + 1), enumerable: true, writable: true, configurable: true });", 'o[k] = plain(v[k], level + 1);']),
];

const filter = process.argv[2];
const run = () => {
  const r = spawnSync(process.execPath, ['bench/cbor-js-test.mjs'], { cwd: work, encoding: 'utf8', timeout: 120000 });
  const out = (r.stdout || '') + (r.stderr || '');
  const failed = out.split('\n').filter((l) => l.startsWith('FAIL ')).map((l) => l.slice(5).trim());
  return { failed, finished: /tests pass/.test(out), out };
};
const fresh = () => {
  rmSync(work, { recursive: true, force: true });
  mkdirSync(`${work}/bench`, { recursive: true });
  cpSync(`${root}js`, `${work}/js`, { recursive: true });
  cpSync(`${root}bench/cbor-js-test.mjs`, `${work}/bench/cbor-js-test.mjs`);
  symlinkSync(`${root}research`, `${work}/research`);
};

let bad = 0;
fresh();
const base = run();
// Known red tests (a bug that the test agent reported, not fixed yet): they fail in the clean copy and do not stop the run.
const KNOWN = /^Dec edge:/;
base.failed = base.failed.filter((n) => !KNOWN.test(n));
console.log(`clean copy: ${base.finished && base.failed.length === 0 ? 'all tests pass (but the known red tests)' : 'FAILS'}`);
if (!base.finished || base.failed.length) { console.log(base.out.slice(-1500)); process.exit(1); }

const rows = [];
for (const m of mutations) {
  if (filter && !m.name.includes(filter)) continue;
  fresh();
  let text = readFileSync(`${work}/${m.file}`, 'utf8');
  for (const [from, to, all] of m.edits) {
    if (!text.includes(from)) { console.log(`ERROR  ${m.name}: text not found in ${m.file}: ${from.slice(0, 60)}`); bad++; text = null; break; }
    text = all ? text.split(from).join(to) : text.replace(from, () => to);
  }
  if (text === null) continue;
  writeFileSync(`${work}/${m.file}`, text);
  const r = run();
  const caught = r.finished && r.failed.some((n) => m.expect.test(n));
  if (!caught) bad++;
  rows.push({ revert: m.name, result: !r.finished ? 'CRASH' : caught ? 'caught' : 'NOT CAUGHT', 'failed tests': r.failed.length, 'first failed': (r.failed[0] || '').slice(0, 70) });
}
console.table(rows);
console.log(`${rows.length - bad} of ${rows.length} reverts caught${bad ? `, ${bad} not` : ''}`);
rmSync(work, { recursive: true, force: true });
process.exit(bad ? 1 : 0);
