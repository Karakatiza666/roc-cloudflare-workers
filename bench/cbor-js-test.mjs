// PLAN.md 8a, the JS half of the value codec (API.md 5, 5.1 HD7, 5.2): js/cbor.js and js/values.js.
// node bench/cbor-js-test.mjs
// Each test has a name and the rules it checks (J1 to J7, RS1, HD7). A failed test prints FAIL and its first line.
// bench/cbor-js-reverts.mjs breaks the code in a copy, one change at a time, and checks that tests fail.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Writer, TooLarge, BufferFull, decode, MAX_DEPTH, Refs, Packed, Kept, toJs, fromJs, pack } from '../js/values.js';
import * as proto from '../research/api-probe/cbor/cbor.mjs';

const hex = (u8) => Buffer.from(u8).toString('hex');
const unhex = (h) => new Uint8Array(Buffer.from(h.replace(/\s/g, ''), 'hex'));
const enc = (v) => hex(toJs(v, new Refs()));
const dec = (h, refs) => fromJs(unhex(h), refs);
const cls = (C, re) => (e) => e instanceof C && (re === undefined || re.test(e.message)) || (console.log('   got:', e), false);
const rangeErr = (h, re) => assert.throws(() => dec(h), cls(RangeError, re), `${h} is a RangeError`);
const typeErr = (h, re) => assert.throws(() => dec(h), cls(TypeError, re), `${h} is a TypeError`);

const rows = JSON.parse(readFileSync(new URL('../research/api-probe/cbor/rows.json', import.meta.url), 'utf8'));
class Thing {}
let failed = 0, count = 0;
const test = (name, fn) => {
  count++;
  try { fn(); console.log('ok   ', name); } catch (e) { failed++; console.log('FAIL ', name, '\n       ', String(e.message).split('\n')[0]); }
};

// Speed is measured first, in a fresh process: after the fuzz tests the same code runs slower, the prototype too.
let speed;
test('speed: the 200 rows encode and decode (the numbers are printed at the end)', () => {
  const time = (f) => { for (let i = 0; i < 300; i++) f(); let best = Infinity; for (let r = 0; r < 7; r++) { const t0 = process.hrtime.bigint(); for (let i = 0; i < 300; i++) f(); best = Math.min(best, Number(process.hrtime.bigint() - t0) / 300 / 1000); } return best.toFixed(1); };
  const refs = new Refs(), w = new Writer(1 << 20), bytes = toJs(rows, refs).slice(), packed = pack(rows).slice();
  assert.deepStrictEqual(fromJs(bytes, refs), rows);
  assert.deepStrictEqual(fromJs(packed, refs), rows);
  speed = {
    bytes: bytes.length,
    table: {
      'toJs, new writer': time(() => toJs(rows, refs)),
      'toJs, reused writer': time(() => { w.reset(); return toJs(rows, refs, w); }),
      'pack': time(() => pack(rows)),
      'fromJs (a tree)': time(() => fromJs(bytes, refs)),
      'fromJs (a Packed value)': time(() => fromJs(packed, refs)),
      'prototype encode': time(() => proto.encode(rows)),
      'prototype decode': time(() => proto.decode(bytes)),
    },
  };
});

// ---- RFC 8949 Appendix A, the part in the profile. [hex, value, written back the same?]
// A vector with a float is written back as f64 only when its hex is f64 (the profile never shortens a float).
const vectors = [
  ['00', 0, 1], ['01', 1, 1], ['0a', 10, 1], ['17', 23, 1], ['1818', 24, 1], ['1819', 25, 1], ['1864', 100, 1],
  ['1903e8', 1000, 1], ['1a000f4240', 1000000, 1], ['1b000000e8d4a51000', 1000000000000, 1],
  ['1bffffffffffffffff', 18446744073709551615n, 0], ['3bffffffffffffffff', -18446744073709551616n, 0],
  ['20', -1, 1], ['29', -10, 1], ['3863', -100, 1], ['3903e7', -1000, 1],
  ['f90000', 0, 0], ['f98000', -0, 0], ['f93c00', 1, 0], ['fb3ff199999999999a', 1.1, 1], ['f93e00', 1.5, 0],
  ['f97bff', 65504, 0], ['fa47c35000', 100000, 0], ['fa7f7fffff', 3.4028234663852886e+38, 0],
  ['fb7e37e43c8800759c', 1.0e+300, 1], ['f90001', 5.960464477539063e-8, 0], ['f90400', 0.00006103515625, 0],
  ['f9c400', -4, 0], ['fbc010666666666666', -4.1, 1], ['f97c00', Infinity, 0], ['f97e00', NaN, 0], ['f9fc00', -Infinity, 0],
  ['fa7f800000', Infinity, 0], ['fa7fc00000', NaN, 0], ['faff800000', -Infinity, 0],
  ['fb7ff0000000000000', Infinity, 1], ['fb7ff8000000000000', NaN, 1], ['fbfff0000000000000', -Infinity, 1],
  ['f4', false, 1], ['f5', true, 1], ['f6', null, 1], ['f7', undefined, 1],
  ['40', new Uint8Array(0), 1], ['4401020304', new Uint8Array([1, 2, 3, 4]), 1],
  ['60', '', 1], ['6161', 'a', 1], ['6449455446', 'IETF', 1], ['62225c', '"\\', 1], ['62c3bc', 'ü', 1], ['63e6b0b4', '水', 1],
  ['64f0908591', '\u{10151}', 1],
  ['80', [], 1], ['83010203', [1, 2, 3], 1], ['8301820203820405', [1, [2, 3], [4, 5]], 1],
  ['98190102030405060708090a0b0c0d0e0f101112131415161718181819', Array.from({ length: 25 }, (_, i) => i + 1), 1],
  ['a0', {}, 1], ['a26161016162820203', { a: 1, b: [2, 3] }, 1], ['826161a161626163', ['a', { b: 'c' }], 1],
  ['a56161614161626142616361436164614461656145', { a: 'A', b: 'B', c: 'C', d: 'D', e: 'E' }, 1],
  ['d818456449455446', 'IETF', 0], // tag 24 (Packed): it reads as the item inside
];
test('HD7 RFC 8949 A: decode of the vectors in the profile', () => {
  for (const [h, v] of vectors) assert.deepStrictEqual(dec(h), v, `decode ${h}`);
});
test('HD7, J1 RFC 8949 A: encode writes the same bytes where the profile does (no -0, no BigInt above i64)', () => {
  let n = 0;
  for (const [h, v, same] of vectors) {
    if (!same || typeof v === 'bigint') continue;
    n++;
    assert.equal(enc(v), h, `encode of ${String(v)}`);
  }
  assert.ok(n > 40);
});
test('HD7 RFC 8949 A: the same value with another width of argument (decode only)', () => {
  const same = [['1800', 0], ['190001', 1], ['1a00000001', 1], ['1b0000000000000001', 1], ['3800', -1], ['390000', -1], ['3a00000000', -1],
    ['3b0000000000000000', -1], ['5800', new Uint8Array(0)], ['780161', 'a'], ['98020102', [1, 2]], ['9a00000001f6', [null]],
    ['b801616101', { a: 1 }], ['bb0000000000000001616101', { a: 1 }], ['d9001841' + '00', 0], ['da0000001841' + '00', 0], ['db000000000000001841' + '00', 0]];
  for (const [h, v] of same) assert.deepStrictEqual(dec(h), v, h);
});
test('HD7 RFC 8949 A: not in the profile is an error (bignums, tags 0 1 23 32, simple values, integer keys)', () => {
  const out = [
    ['c249010000000000000000', 'tag 2'], ['c349010000000000000000', 'tag 3'], ['c074323031332d30332d32315432303a30343a30305a', 'tag 0'],
    ['c11a514b67b0', 'tag 1'], ['c1fb41d452d9ec200000', 'tag 1'], ['d74401020304', 'tag 23'],
    ['d82076687474703a2f2f7777772e6578616d706c652e636f6d', 'tag 32'], ['f0', 'simple value 16'], ['f8ff', 'simple value 24'],
    ['a201020304', 'a map key must be text'],
  ];
  for (const [h, why] of out) typeErr(h, new RegExp(why.replace(/[()]/g, '.')));
});
test('HD7 RFC 8949 A: indefinite lengths are an error (the 11 vectors)', () => {
  for (const h of ['5f42010243030405ff', '7f657374726561646d696e67ff', '9fff', '9f018202039f0405ffff', '9f01820203820405ff',
    '83018202039f0405ff', '83019f0203ff820405', '9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff',
    'bf61610161629f0203ffff', '826161bf61626163ff', 'bf6346756ef563416d7421ff']) typeErr(h, /indefinite/);
});
test('profile: reserved values 28 to 30 are an error in each major type', () => {
  for (let major = 0; major < 8; major++) for (const info of [28, 29, 30]) typeErr(hex([major << 5 | info]), /reserved/);
});

// ---- Errors of the reader
test('profile: a cut input is a RangeError at each length (also tag 27 and tag 24)', () => {
  const refs = new Refs();
  const whole = toJs({ a: [1, 'é'.repeat(30), new Uint8Array(30), 2.5, -300, 1n << 60n], r: new Thing(), e: new RangeError('m'), p: new Packed([1, 'two']) }, refs).slice();
  assert.ok(whole.length > 100);
  for (let n = 0; n < whole.length; n++) assert.throws(() => fromJs(whole.subarray(0, n), refs), cls(RangeError, /input ends|longer than the input/), `cut at ${n}`);
  assert.doesNotThrow(() => fromJs(whole, refs));
});
test('profile: a length past the input is an error before any allocation (arrays, maps, text, bytes)', () => {
  for (const h of ['9bffffffffffffffff', '9affffffff', '99ffff00', 'bbffffffffffffffff', 'baffffffff00', '5affffffff', '7bffffffffffffffff', '5b0000000100000000'])
    rangeErr(h, /longer than the input/);
});
test('profile: bytes after the value are an error', () => {
  typeErr('0101', /bytes after the value/);
  typeErr('f6f6', /bytes after the value/);
  typeErr('d818 42 01 02'.replace(/ /g, ''), /tag 24/);
});
test('profile: text must be valid UTF-8, short and long (fatal decoder)', () => {
  const bad = ['c328', 'c080', 'eda080', 'e6b0', 'f090', 'ff', 'fe', 'f4908080', 'e0809f'];
  for (const b of bad) {
    typeErr((0x60 + b.length / 2).toString(16) + b, /UTF-8/); // a short text
    typeErr('78' + (20 + b.length / 2).toString(16) + '61'.repeat(20) + b, /UTF-8/); // a long text
  }
  typeErr('a1' + '62c328' + '01', /UTF-8/); // as a map key
});
test('profile: a U+FEFF at the start of a text stays (the TextDecoder default drops it)', () => {
  assert.equal(dec('63efbbbf').length, 1);
  assert.equal(dec('78' + (3 + 20).toString(16) + 'efbbbf' + '61'.repeat(20)).length, 21);
  assert.equal(dec(enc('﻿x')), '﻿x');
});
test('profile: a map key must be text; a key of 24 bytes or more reads; __proto__ is a key, not a prototype', () => {
  typeErr('a10101', /map key must be text/);
  typeErr('a1f601', /map key must be text/);
  const long = 'k'.repeat(40);
  assert.deepStrictEqual(dec(enc({ [long]: 1 })), { [long]: 1 });
  const o = dec('a1695f5f70726f746f5f5f01');
  assert.equal(Object.getPrototypeOf(o), Object.prototype);
  assert.deepEqual(Object.keys(o), ['__proto__']);
  assert.equal(Object.getOwnPropertyDescriptor(o, '__proto__').value, 1);
  assert.equal(o.polluted, undefined);
  const back = dec(enc(JSON.parse('{"__proto__":{"x":1}}')));
  assert.equal(Object.getPrototypeOf(back), Object.prototype);
  assert.equal({}.x, undefined);
});
test('profile: the key cache keeps the right string (the same length at the same place, other bytes)', () => {
  const v = [{ ab: 1, cd: 2 }, { ab: 3, ce: 4 }, { xy: 5 }, { ab: 6, cf: 7 }];
  assert.deepStrictEqual(dec(enc(v)), v);
});
test('J3 depth: 64 levels pass and 65 fail, both ways, for arrays and maps', () => {
  const nestA = (n) => { let v = []; for (let i = 1; i < n; i++) v = [v]; return v; };
  const nestO = (n) => { let v = {}; for (let i = 1; i < n; i++) v = { a: v }; return v; };
  for (const nest of [nestA, nestO]) {
    assert.doesNotThrow(() => toJs(nest(MAX_DEPTH), new Refs()));
    assert.throws(() => toJs(nest(MAX_DEPTH + 1), new Refs()), cls(RangeError, /deeper than 64/));
  }
  const bytesA = (n) => unhex('81'.repeat(n - 1) + '80');
  const bytesO = (n) => unhex('a16161'.repeat(n - 1) + 'a0');
  for (const bytes of [bytesA, bytesO]) {
    assert.doesNotThrow(() => fromJs(bytes(MAX_DEPTH)));
    assert.throws(() => fromJs(bytes(MAX_DEPTH + 1)), cls(RangeError, /deeper than 64/));
  }
  assert.equal(MAX_DEPTH, 64);
});
test('J3 depth: a cycle (array, object, Map, Packed) is a RangeError; Packed and Map count their levels', () => {
  const a = []; a.push(a);
  const o = {}; o.o = o;
  const m = new Map(); m.set('k', m);
  for (const v of [a, o, m, new Packed(a)]) assert.throws(() => toJs(v, new Refs()), cls(RangeError, /deeper than 64.*cycle/));
  let n = []; for (let i = 1; i < 64; i++) n = [n]; // 64 levels
  assert.doesNotThrow(() => toJs(new Packed(n), new Refs()));
  assert.throws(() => toJs([new Packed(n)], new Refs()), cls(RangeError, /deeper/)); // 65 levels in all
  assert.throws(() => fromJs(toJsUnchecked([new Packed(n)])), cls(RangeError, /deeper/)); // and the reader counts the same
  let m62 = []; for (let i = 1; i < 62; i++) m62 = [m62];
  assert.throws(() => toJs(new Map([['k', n]]), new Refs()), cls(RangeError, /deeper/)); // the list of pairs, a pair, then 64
  assert.doesNotThrow(() => toJs(new Map([['k', m62]]), new Refs()));
});
// 65 levels with a Packed inside: the writer refuses, so the bytes are made by hand (tag 24 around 63 levels in 2 levels).
function toJsUnchecked() {
  const inner = unhex('81'.repeat(63) + '80');
  return Uint8Array.from([0x81, 0xd8, 0x18, 0x58, inner.length, ...inner]);
}

// ---- Widths: the shortest (the head of a container too)
// The bytes of a head, made apart from the writer.
const head = (major, n) => {
  n = BigInt(n);
  if (n < 24n) return [(major << 5) | Number(n)];
  const w = n < 0x100n ? 1 : n < 0x10000n ? 2 : n < 0x100000000n ? 4 : 8, b = Buffer.alloc(8);
  b.writeBigUInt64BE(n);
  return [(major << 5) | (24 + Math.log2(w)), ...b.subarray(8 - w)];
};
const headHex = (major, n) => hex(head(major, n));
const edges = [0, 1, 23, 24, 255, 256, 65535, 65536];
test('profile: the writer takes the shortest width at each limit (integers, text, bytes, array, map)', () => {
  for (const n of [...edges, 4294967295, 4294967296, 2 ** 53 - 1]) {
    assert.equal(enc(n), headHex(0, n), `int ${n}`);
    if (n < 2 ** 53 - 1) assert.equal(enc(-1 - n), headHex(1, n), `negative int ${-1 - n}`);
  }
  for (const n of edges) {
    assert.equal(enc('a'.repeat(n)).slice(0, headHex(3, n).length), headHex(3, n), `text ${n}`);
    assert.equal(enc(new Uint8Array(n)).slice(0, headHex(2, n).length), headHex(2, n), `bytes ${n}`);
    assert.equal(enc(new Array(n).fill(null)).slice(0, headHex(4, n).length), headHex(4, n), `array ${n}`);
    const o = Object.fromEntries(Array.from({ length: n }, (_, i) => ['k' + i, 0]));
    assert.equal(enc(o).slice(0, headHex(5, n).length), headHex(5, n), `map ${n}`);
  }
  // Non-ASCII text moves its bytes when the reserved head was longer than needed.
  for (const n of [1, 7, 8, 12, 13, 50, 85, 86, 21845, 21846]) {
    const s = 'é'.repeat(n), b = toJs(s, new Refs());
    assert.equal(hex(b.subarray(0, head(3, 2 * n).length)), headHex(3, 2 * n), `é x ${n}`);
    assert.equal(b.length, head(3, 2 * n).length + 2 * n);
    assert.equal(fromJs(b), s);
  }
});
test('profile: a small buffer that grows keeps short text (the head and the bytes at the end of the buffer)', () => {
  const v = ['a', 'bc', 'def', 'ghijk', 'x'.repeat(23), 'y'.repeat(24), 'z'.repeat(47), 'é', '', 'w'];
  const want = hex(toJs(v, new Refs(), new Writer(4096)));
  for (let size = 1; size < 200; size++) assert.equal(hex(toJs(v, new Refs(), new Writer(size))), want, `initial size ${size}`);
});

// ---- J1 to J7
test('J1 primitives: undefined, null, Bool, safe integer is Int, other Number is Num (f64), text', () => {
  assert.equal(enc(undefined), 'f7'); assert.equal(enc(null), 'f6'); assert.equal(enc(true), 'f5'); assert.equal(enc(false), 'f4');
  assert.equal(enc(7), '07'); assert.equal(enc(-7), '26'); assert.equal(enc(2 ** 53 - 1), '1b001fffffffffffff');
  assert.equal(enc(1.5), 'fb3ff8000000000000'); assert.equal(enc(2 ** 53), 'fb4340000000000000'); assert.equal(enc(1e21), 'fb444b1ae4d6e2ef50');
  assert.equal(enc(NaN), 'fb7ff8000000000000'); assert.equal(enc(-Infinity), 'fbfff0000000000000');
  assert.equal(enc(-0), '00'); // a safe integer: the sign of zero is lost
  assert.equal(dec(enc(2 ** 53)), 2 ** 53);
});
test('J1 a lone surrogate becomes U+FFFD, short and long text', () => {
  assert.equal(dec(enc('a\ud800b')), 'a�b');
  assert.equal(dec(enc('\udc00')), '�');
  assert.equal(dec(enc('x'.repeat(100) + '\ud83d')), 'x'.repeat(100) + '�');
  assert.equal(dec(enc('😀')), '\u{1f600}');
});
test('J1 BigInt: in i64 it is Int; outside 64 bits it is a RangeError; above i64 is a RangeError in a tree', () => {
  for (const v of [0n, -1n, 5n, 2n ** 63n - 1n, -(2n ** 63n)]) assert.deepStrictEqual(dec(enc(v)), v >= -(2n ** 53n) && v <= 2n ** 53n ? Number(v) : v);
  for (const v of [2n ** 63n, 2n ** 64n - 1n, 2n ** 64n, -(2n ** 63n) - 1n, -(2n ** 64n), 2n ** 100n, -(2n ** 100n)]) {
    assert.throws(() => enc(v), cls(RangeError, /outside/), String(v));
  }
});
test('J1 Int in, Number or BigInt out: up to 2^53 a Number, above a BigInt (and the same for negative)', () => {
  assert.equal(typeof dec('1b0020000000000000'), 'number');
  assert.equal(dec('1b0020000000000000'), 2 ** 53);
  assert.equal(dec('1b0020000000000001'), 9007199254740993n);
  assert.equal(dec('3b001fffffffffffff'), -(2 ** 53));
  assert.equal(typeof dec('3b001fffffffffffff'), 'number');
  assert.equal(dec('3b0020000000000000'), -9007199254740993n);
  assert.equal(dec('1b00000001ffffffff'), 8589934591);
});
test('integers: 2^53 + 1, 2^64 - 1 (Packed) and -2^63 round trip, in a tree and in Packed', () => {
  const refs = new Refs();
  for (const v of [2n ** 53n + 1n, 2n ** 53n + 2n, 2n ** 62n + 12345n, -(2n ** 63n), -(2n ** 53n) - 1n, 2n ** 63n - 1n]) {
    assert.deepStrictEqual(fromJs(toJs(v, refs), refs), v, `tree ${v}`);
    assert.deepStrictEqual(fromJs(pack(v)), v, `packed ${v}`);
    assert.deepStrictEqual(fromJs(toJs([v, { k: v }], refs), refs), [v, { k: v }]);
  }
  assert.deepStrictEqual(fromJs(pack(2n ** 64n - 1n)), 2n ** 64n - 1n);
  assert.deepStrictEqual(fromJs(pack([2n ** 64n - 1n, 2n ** 63n])), [2n ** 64n - 1n, 2n ** 63n]);
  assert.equal(hex(pack(2n ** 64n - 1n)), 'd81849' + '1bffffffffffffffff');
  assert.throws(() => pack(2n ** 64n), cls(RangeError, /outside/));
  assert.throws(() => pack(-(2n ** 63n) - 1n), cls(RangeError, /outside/));
});
test('J2 Uint8Array, ArrayBuffer, DataView, other typed arrays and Buffer give Bytes (a copy, at the right offset)', () => {
  const ab = new ArrayBuffer(16); new Uint8Array(ab).forEach((_, i, a) => { a[i] = i; });
  assert.deepStrictEqual(dec(enc(new Uint8Array(ab, 4, 3))), new Uint8Array([4, 5, 6]));
  assert.deepStrictEqual(dec(enc(ab)), new Uint8Array(ab));
  assert.deepStrictEqual(dec(enc(new DataView(ab, 2, 2))), new Uint8Array([2, 3]));
  assert.deepStrictEqual(dec(enc(new Uint16Array(ab, 2, 2))), new Uint8Array([2, 3, 4, 5]));
  assert.deepStrictEqual(dec(enc(new Float64Array([1]))), new Uint8Array(new Float64Array([1]).buffer));
  assert.deepStrictEqual(dec(enc(Buffer.from('hi'))), new Uint8Array([104, 105]));
  const input = unhex('4401020304'), out = dec('4401020304');
  assert.equal(Object.getPrototypeOf(out), Uint8Array.prototype);
  assert.notEqual(out.buffer, input.buffer);
  const inBuf = Buffer.from('4401020304', 'hex'); // a Buffer input: the result is still a Uint8Array copy
  const out2 = fromJs(inBuf);
  inBuf[1] = 99;
  assert.deepStrictEqual(out2, new Uint8Array([1, 2, 3, 4]));
  assert.equal(Object.getPrototypeOf(out2), Uint8Array.prototype);
});
test('J3 Array, plain object (also null prototype): deep, in key order; undefined values stay', () => {
  const np = Object.create(null); np.z = 1; np.a = [2];
  assert.equal(enc({ b: 1, a: 2, 1: 3 }), 'a3' + '6131' + '03' + '6162' + '01' + '6161' + '02');
  assert.deepStrictEqual(dec(enc(np)), { z: 1, a: [2] });
  assert.deepStrictEqual(dec(enc({ u: undefined, n: null })), { u: undefined, n: null });
  assert.deepStrictEqual(dec(enc([[], {}, [[]]])), [[], {}, [[]]]);
});
test('J4 Date is milliseconds since 1970 (Int, or Num for an invalid date)', () => {
  assert.equal(enc(new Date(1760000000123)), enc(1760000000123));
  assert.equal(dec(enc(new Date(0))), 0);
  assert.equal(dec(enc(new Date(-1))), -1);
  assert.ok(Number.isNaN(dec(enc(new Date(NaN)))));
  assert.equal(enc(new Date(NaN)), 'fb7ff8000000000000');
});
test('J5 Headers, Map, URLSearchParams are an Arr of [key, value] pairs', () => {
  const pairs = [['a', '1'], ['b', '2']];
  assert.deepStrictEqual(dec(enc(new Map(pairs))), pairs);
  assert.deepStrictEqual(dec(enc(new URLSearchParams('a=1&b=2'))), pairs);
  assert.deepStrictEqual(dec(enc(new Headers({ A: '1', B: '2' }))), pairs); // Headers makes the names lower case
  assert.deepStrictEqual(dec(enc(new Map([[1, { x: new Map([['y', 1]]) }]]))), [[1, { x: [['y', 1]] }]]);
  const h = new Headers(); h.append('set-cookie', 'a=1'); h.append('set-cookie', 'b=2');
  assert.equal(dec(enc(h)).length, 2);
});
test('J6 Error and DOMException are Error(name, message); the reader makes an Error', () => {
  assert.equal(enc(new TypeError('bad')), 'd81b83' + '65' + '4572726f72' + '69' + '54797065457272' + '6f72' + '63' + '626164');
  for (const e of [new TypeError('bad'), new RangeError(''), new Error('é'), new DOMException('gone', 'AbortError')]) {
    const back = dec(enc(e));
    assert.ok(back instanceof Error);
    assert.equal(back.name, e.name);
    assert.equal(back.message, e.message);
  }
  assert.equal(dec(enc({ e: new DOMException('x', 'NotFoundError') })).e.name, 'NotFoundError');
});
test('J7, RS1 other objects (class instance, function, Response, Set, Symbol) are Ref(id) of the ref table; tag 27', () => {
  class Stream {}
  const refs = new Refs(), s = new Stream(), f = () => 1, r = new Response('x'), set = new Set([1]), sym = Symbol('s');
  const bytes = toJs([s, f, r, set, sym], refs);
  assert.equal(hex(bytes), '85' + ['01', '02', '03', '04', '05'].map((id) => 'd81b82' + '63526566' + id).join(''));
  const back = fromJs(bytes, refs);
  assert.deepStrictEqual(back.map((x, i) => x === [s, f, r, set, sym][i]), [true, true, true, true, true]);
  assert.equal(refs.size, 5);
});
test('RS1 the ref table gives one id for one object: two refs of an object in a task are the same id', () => {
  const refs = new Refs(), a = new (class A {})(), b = new (class B {})();
  const id = (o) => refs.idOf(o);
  assert.equal(id(a), id(a));
  assert.notEqual(id(a), id(b));
  assert.equal(id(a), 1);
  const bytes = toJs([a, b, a, { x: a }], refs);
  assert.equal(hex(bytes), '84' + 'd81b8263526566' + '01' + 'd81b8263526566' + '02' + 'd81b8263526566' + '01' + 'a1' + '6178' + 'd81b8263526566' + '01');
  assert.equal(refs.size, 2);
  const t2 = new Refs(); // another task, another table
  assert.equal(t2.idOf(b), 1);
});
test('RS1 a Ref gives back its object; an unknown id, an id of 0 and a Ref with no table are errors; clear() empties the table', () => {
  const refs = new Refs(), o = new (class O {})();
  const bytes = toJs(o, refs).slice();
  assert.equal(fromJs(bytes, refs), o);
  assert.throws(() => fromJs(unhex('d81b8263526566' + '09'), refs), cls(RangeError, /unknown ref 9/));
  assert.throws(() => fromJs(unhex('d81b8263526566' + '00'), refs), cls(RangeError, /unknown ref 0/));
  assert.throws(() => fromJs(bytes), cls(TypeError, /ref table/));
  assert.throws(() => refs.get(-1), RangeError);
  refs.clear();
  assert.equal(refs.size, 0);
  assert.throws(() => fromJs(bytes, refs), cls(RangeError, /unknown ref 1/));
  assert.equal(refs.get(refs.idOf(o)), o); // the ids of the old table are gone
  assert.equal(refs.idOf(o), 1);
});
test('tag 27: only ["Ref", id] and ["Error", name, message] with the right types', () => {
  const refs = new Refs(); refs.idOf({});
  assert.throws(() => dec('d81b8263526566' + '1b0000000100000000', refs), cls(TypeError, /32 bit/)); // an id past u32 is not a ref id
  for (const h of ['d81b80', 'd81b8163526566', 'd81b83635265660000', 'd81b826345727272', 'd81b8263526566' + '6161', 'd81b8263526566' + '1b0000000100000000',
    'd81b8263526566' + '20', 'd81b83654572726f72' + '01' + '6161', 'd81b83654572726f72' + '6161' + '01', 'd81b8265457272' + '6f72' + '6161', 'd81b01', 'd81b82' + '01' + '01',
    'd81b8263526566' + 'd81b8263526566' + '01', 'd81b8463526566000000']) {
    assert.throws(() => dec(h, refs), (e) => e instanceof TypeError || e instanceof RangeError, h);
  }
  assert.throws(() => dec('d81b83' + '63526566' + '01' + '02', refs), cls(TypeError, /tag 27/)); // "Ref" with 3 items
  assert.throws(() => dec('d81b82' + '654572726f72' + '6161', refs), cls(TypeError, /tag 27/)); // "Error" with 2 items
  assert.equal(dec('d81b82' + '63526566' + '01', refs), refs.get(1));
  assert.equal(dec('db000000000000001b82' + '63526566' + '01', refs), refs.get(1)); // a long head of the tag
});

// ---- Packed (API.md 5.2)
const bstrHead = (n) => (n < 24 ? Buffer.from([0x40 | n]) : n < 256 ? Buffer.from([0x58, n]) : n < 65536 ? Buffer.from([0x59, n >> 8, n & 255]) : Buffer.from([0x5a, n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255]));
test('Packed: 200 rows are tag 24 and the bytes of the prototype codec (research/api-probe/cbor/cbor.mjs)', () => {
  assert.equal(rows.length, 200);
  const oracle = proto.encode(rows), got = pack(rows);
  assert.equal(oracle.length, 56382);
  assert.equal(hex(got), hex(Buffer.concat([Buffer.from([0xd8, 0x18]), bstrHead(oracle.length), oracle])));
  assert.deepStrictEqual(fromJs(got), rows);
  assert.deepStrictEqual(fromJs(toJs(rows, new Refs())), rows); // the same rows as a plain tree: the same bytes as the oracle
  assert.equal(hex(toJs(rows, new Refs())), hex(oracle));
});
test('Packed: the head of the byte string has the shortest width (1, 2, 3 and 5 bytes) and the content moves down', () => {
  for (const n of [0, 1, 20, 21, 22, 23, 24, 250, 251, 252, 253, 254, 300, 65530, 65531, 65532, 70000]) {
    const inner = proto.encode(new Uint8Array(n)), got = pack(new Uint8Array(n));
    assert.equal(hex(got), hex(Buffer.concat([Buffer.from([0xd8, 0x18]), bstrHead(inner.length), inner])), `bytes ${n}`);
    assert.deepStrictEqual(fromJs(got), new Uint8Array(n));
  }
});
test('Packed: RFC 8949 A tag 24 (d818456449455446) is pack("IETF"); a Packed in a tree, at any place', () => {
  assert.equal(hex(pack('IETF')), 'd818456449455446');
  const refs = new Refs();
  assert.equal(enc([new Packed({ a: 1 }), 2]), '82' + 'd818' + '44' + 'a1616101' + '02');
  assert.deepStrictEqual(fromJs(toJs({ meta: 1, rows: new Packed(rows.slice(0, 3)) }, refs), refs), { meta: 1, rows: rows.slice(0, 3) });
  assert.deepStrictEqual(fromJs(toJs([new Packed(7)], refs), refs), [7]);
});
test('Packed: typed data has no Ref, no nested Packed and no Error (TypeError); Date, Map and bytes are as in a tree', () => {
  class X {}
  assert.throws(() => pack(new TypeError('x')), cls(TypeError, /Error/));
  assert.throws(() => pack({ e: new DOMException('m', 'AbortError') }), cls(TypeError, /Error/));
  assert.throws(() => toJs([new Packed([new RangeError('r')])], new Refs()), cls(TypeError, /Error/));
  assert.throws(() => pack(new X()), cls(TypeError, /no codec/));
  assert.throws(() => pack({ a: [() => 1] }), cls(TypeError, /no codec/));
  assert.throws(() => pack(Symbol('s')), cls(TypeError, /no codec/));
  assert.throws(() => pack(new Packed(1)), cls(TypeError, /nested|Packed/));
  assert.throws(() => toJs(new Packed(new Packed(1)), new Refs()), cls(TypeError, /Packed/));
  assert.throws(() => toJs(new Packed([new X()]), new Refs()), cls(TypeError, /no codec/));
  assert.deepStrictEqual(fromJs(pack([new Date(5), new Map([['a', 1]]), new Uint8Array([1])])), [5, [['a', 1]], new Uint8Array([1])]);
});
test('Packed: maxBytes is a TooLarge (a RangeError with the name TooLarge); the limit is on the CBOR of the value', () => {
  const size = proto.encode(rows).length;
  assert.doesNotThrow(() => pack(rows, { maxBytes: size }));
  for (const limit of [size - 1, 1000, 1]) {
    assert.throws(() => pack(rows, { maxBytes: limit }), (e) => e instanceof RangeError && e instanceof TooLarge && e.name === 'TooLarge' && /larger than/.test(e.message));
  }
  assert.throws(() => pack(new Uint8Array(100), { maxBytes: 50 }), (e) => e.name === 'TooLarge');
  assert.throws(() => pack('x'.repeat(100), { maxBytes: 50 }), (e) => e.name === 'TooLarge');
  assert.throws(() => pack('é'.repeat(100), { maxBytes: 50 }), (e) => e.name === 'TooLarge');
  assert.throws(() => pack(Array(100).fill(null), { maxBytes: 50 }), (e) => e.name === 'TooLarge');
  assert.doesNotThrow(() => pack([1, 2, 3], { maxBytes: 4 })); // 83 01 02 03
  assert.throws(() => pack([1, 2, 3], { maxBytes: 3 }), (e) => e.name === 'TooLarge');
  // In a tree, the limit of a Packed is its own, and the bytes after it still write.
  assert.throws(() => toJs([new Packed(rows, 100)], new Refs()), (e) => e.name === 'TooLarge');
  assert.deepStrictEqual(fromJs(toJs([new Packed([1], 4), new Packed([2, 3], 4), 'after'], new Refs())), [[1], [2, 3], 'after']);
});
test('Writer: maxBytes of the whole output is a TooLarge (at the limit it passes)', () => {
  assert.equal(hex(toJs('abc', new Refs(), new Writer(64, { maxBytes: 4 }))), '63616263');
  assert.throws(() => toJs('abc', new Refs(), new Writer(64, { maxBytes: 3 })), (e) => e.name === 'TooLarge');
  assert.throws(() => toJs(rows, new Refs(), new Writer(64, { maxBytes: 1000 })), (e) => e instanceof TooLarge);
  assert.throws(() => toJs(Array(10).fill(null), new Refs(), new Writer(64, { maxBytes: 5 })), (e) => e instanceof TooLarge);
});
test('Writer: a caller buffer (at an offset, in a bigger buffer) with no grow: it writes there; a full buffer is a BufferFull', () => {
  const mem = new Uint8Array(256).fill(0xee), view = mem.subarray(100, 140);
  const out = toJs([1, 'ab', 300], new Refs(), new Writer(view));
  assert.equal(out.buffer, mem.buffer);
  assert.equal(out.byteOffset, 100);
  assert.equal(hex(out), '83' + '01' + '626162' + '19012c');
  assert.ok(mem.subarray(0, 100).every((x) => x === 0xee) && mem.subarray(140).every((x) => x === 0xee));
  assert.throws(() => toJs('x'.repeat(30), new Refs(), new Writer(new Uint8Array(8))), (e) => e instanceof BufferFull && e instanceof RangeError && e.name === 'BufferFull');
  assert.throws(() => toJs([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], new Refs(), new Writer(new Uint8Array(12))), BufferFull);
});
test('Writer: grow(min, old) gives the new buffer (a wasm memory grow, for example); the used bytes are copied; reset() reuses', () => {
  const calls = [];
  let mem = new Uint8Array(new ArrayBuffer(32));
  const grow = (min, old) => { calls.push([min, old.length]); return new Uint8Array(new ArrayBuffer(Math.max(min, old.length * 2) + 7), 7); };
  const w = new Writer(mem, { grow });
  const out = toJs(rows.slice(0, 10), new Refs(), w);
  assert.ok(calls.length >= 1 && calls.every(([min, len]) => min > len));
  assert.equal(hex(out), hex(proto.encode(rows.slice(0, 10))));
  w.reset();
  assert.equal(hex(toJs('a', new Refs(), w)), '6161');
  assert.throws(() => toJs(rows, new Refs(), new Writer(mem, { grow: (min) => new Uint8Array(1) })), cls(RangeError, /grow gave less/));
});
test('Writer: a grow that copies (copies: true, as the result block in wasm memory) gets the used count; the writer does not copy', () => {
  // The memory moves at each grow, as wasm memory after a js_alloc that grows it: the old view is detached.
  let mem = new ArrayBuffer(64), at = 8;
  const grow = (min, old, used) => {
    const next = new ArrayBuffer(mem.byteLength + Math.max(min, old.length * 2) + 16);
    new Uint8Array(next).set(new Uint8Array(mem));
    const to = mem.byteLength + 8;
    new Uint8Array(next).copyWithin(to, at, at + used);
    structuredClone(mem, { transfer: [mem] }); // detach the old memory
    mem = next; at = to;
    return new Uint8Array(mem, at, Math.max(min, old.length * 2));
  };
  const w = new Writer(new Uint8Array(mem, at, 16), { grow, copies: true });
  const out = toJs(rows.slice(0, 10), new Refs(), w);
  assert.equal(hex(out), hex(proto.encode(rows.slice(0, 10))));
});
test('Kept (the op Keep): a plain value, an array and a promise are a Ref; in Packed data a TypeError', () => {
  const refs = new Refs(), p = Promise.resolve(1), a = [1];
  for (const v of [7, a, p, null]) {
    const back = fromJs(toJs(new Kept(v), refs), refs);
    assert.strictEqual(back, v);
  }
  assert.equal(enc(new Kept(7)).slice(0, 14), 'd81b8263526566');
  assert.throws(() => pack(new Kept(7)), cls(TypeError, /no codec/));
});
test('Packed: a Packed inside Packed data, a byte string of other kind, and bytes after the item are errors in the reader', () => {
  typeErr('d818' + '41' + '00' + '00', /bytes after the value/);
  typeErr('d818' + '60', /tag 24 needs a byte string/);
  typeErr('d818' + '42' + '0001', /tag 24/);
  typeErr('d818' + '41' + 'ff', /indefinite/);
  rangeErr('d818' + '45' + '00', /longer than the input/);
  rangeErr('d818' + '42' + '18', /longer than the input/);
  rangeErr('d818' + '41' + '18', /input ends/); // cut inside the packed item
  typeErr('d818' + '42' + 'c11a', /tag 1/);
  assert.strictEqual(dec('d818' + '44' + 'd8184100'), 0); // tag 24 inside tag 24 reads
});

// ---- Fuzz
const rng = (seed) => () => { seed |= 0; seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
function gen(r, st, depth) {
  const pick = (n) => Math.floor(r() * n);
  const leaf = depth >= 6 || r() < 0.35;
  const kinds = leaf ? 16 : 22;
  switch (pick(kinds)) {
    case 0: return undefined;
    case 1: return null;
    case 2: return r() < 0.5;
    case 3: return pick(24) - 4;
    case 4: return Math.round((r() - 0.5) * 2 ** (1 + pick(52)));
    case 5: return [0.5, -2.25, NaN, Infinity, -Infinity, 1e300, 2 ** 53, 5e-324, 1.1][pick(9)] * (r() < 0.3 ? -1 : 1);
    case 6: { const b = BigInt.asIntN(64, BigInt(Math.floor(r() * 2 ** 32)) << 32n | BigInt(Math.floor(r() * 2 ** 32))); return b; }
    case 7: { st.u64 = true; return BigInt.asUintN(64, BigInt(Math.floor(r() * 2 ** 32)) << 32n | BigInt(Math.floor(r() * 2 ** 32))); }
    case 8: return ['', 'a', 'key', 'ab', 'hello world', 'x'.repeat(pick(60)), 'é'.repeat(pick(40)), '\ud800', 'a\udc00b', '\u{1f600}'.repeat(pick(20)), '﻿x', '__proto__'][pick(12)];
    case 9: return Uint8Array.from({ length: pick(40) }, () => pick(256));
    case 10: return new Date(Math.round((r() - 0.3) * 2 ** (30 + pick(20))));
    case 11: st.thing = true; return new Thing();
    case 12: st.error = true; return new Error(['m', 'é', ''][pick(3)]);
    case 13: return pick(2) ? 'k' + pick(5) : pick(100);
    case 14: return -pick(2 ** 31) * pick(2 ** 20);
    case 15: return 2 ** pick(53) * (r() < 0.5 ? -1 : 1);
    case 16: case 17: case 18: { const n = pick(5); return Array.from({ length: n }, () => gen(r, st, depth + 1)); }
    case 19: case 20: { const o = {}; for (let i = pick(5); i > 0; i--) Object.defineProperty(o, ['a', 'b', 'id', 'name', 'k1', '__proto__', 'é', 'long_key_' + pick(30)][pick(8)], { value: gen(r, st, depth + 1), enumerable: true, writable: true, configurable: true }); return o; }
    default: { st.diff = false; return new Map(Array.from({ length: pick(3) }, () => ['k' + pick(4), gen(r, st, depth + 1)])); }
  }
}
// What a value becomes after one trip: the rules of J1 to J7 as a function (an oracle written apart from the codec).
function canon(v) {
  if (typeof v === 'bigint') return v >= -(2n ** 53n) && v <= 2n ** 53n ? Number(v) : v;
  if (typeof v === 'number') return Object.is(v, -0) ? 0 : v;
  if (typeof v === 'string') return v.toWellFormed();
  if (v === null || typeof v !== 'object') return v;
  if (v instanceof Uint8Array) return { $bytes: [...v] };
  if (v instanceof Date) return canon(v.getTime());
  if (v instanceof Map) return [...v].map(canon);
  if (v instanceof Error) return { $error: [v.name, v.message] };
  if (Array.isArray(v)) return v.map(canon);
  if (v instanceof Thing) return v;
  const o = {};
  for (const k of Object.keys(v)) Object.defineProperty(o, k, { value: canon(v[k]), enumerable: true, writable: true, configurable: true });
  return o;
}
test('fuzz: 10,000 seeded random values round trip as a Js tree (J1 to J7) and as Packed; bytes equal the prototype codec', () => {
  const r = rng(20261016);
  let trees = 0, packs = 0, diffs = 0;
  for (let i = 0; i < 10000; i++) {
    const st = { diff: true };
    const v = gen(r, st, 0), refs = new Refs();
    const want = canon(v);
    if (!st.u64) {
      const bytes = toJs(v, refs).slice();
      assert.deepStrictEqual(canon(fromJs(bytes, refs)), want, `tree ${i}`);
      assert.equal(hex(toJs(fromJs(bytes, refs), refs)), hex(bytes), `canonical ${i}`);
      trees++;
    }
    // A Map or an object can drop a generated Error (a key twice): look in the value.
    const hasError = (x) => x instanceof Error || (x instanceof Map ? [...x.values()].some(hasError) : x !== null && typeof x === 'object' && !(x instanceof Uint8Array) && !(x instanceof Date) && Object.values(x).some(hasError));
    st.error = hasError(v);
    if (st.error && !st.thing) assert.throws(() => pack(v), TypeError, `packed error ${i}`);
    if (!st.thing && !st.error) {
      const p = pack(v);
      assert.deepStrictEqual(canon(fromJs(p)), want, `packed ${i}`);
      packs++;
      if (st.diff && !(v instanceof Map)) {
        const o = proto.encode(v);
        assert.equal(hex(p), hex(Buffer.concat([Buffer.from([0xd8, 0x18]), bstrHead(o.length), o])), `oracle ${i}`);
        diffs++;
      }
    }
  }
  assert.ok(trees > 6000 && packs > 4000 && diffs > 1500, `${trees} trees, ${packs} packs, ${diffs} oracle checks`);
});
test('fuzz: 10,000 mutated and cut inputs give a value or a RangeError or a TypeError, never a hang or another error', () => {
  const r = rng(77), pick = (n) => Math.floor(r() * n);
  const refs = new Refs();
  let errors = 0, values = 0;
  for (let i = 0; i < 10000; i++) {
    const v = gen(r, { diff: true }, 0);
    let b;
    try { b = Uint8Array.from(toJs(v, refs)); } catch (e) { assert.ok(e instanceof RangeError); continue; }
    for (let m = pick(4); m >= 0 && b.length > 0; m--) {
      const k = pick(4);
      if (k === 0) b[pick(b.length)] = pick(256);
      else if (k === 1) b = b.subarray(0, pick(b.length));
      else if (k === 2) { b = Uint8Array.from([...b.subarray(0, pick(b.length)), pick(256), ...b.subarray(pick(b.length))]); }
      else b[pick(b.length)] ^= 1 << pick(8);
    }
    try { fromJs(b, refs); values++; } catch (e) { errors++; assert.ok(e instanceof RangeError || e instanceof TypeError, `bad error ${e}`); assert.ok(/CBOR|ref/.test(e.message), e.message); }
  }
  assert.ok(errors > 3000 && values > 500, `${errors} errors, ${values} values`);
});

// ---- Speed (the numbers)
if (speed) {
  console.log(`speed, 200 rows (${speed.bytes} B), best of 7 rounds of 300, µs (API.md 5.1, 5.2: encode 79 to 90 with the prototype, decode about 100):`);
  console.table(speed.table);
}

console.log(`${count - failed} of ${count} tests pass`);
process.exit(failed === 0 ? 0 : 1);
