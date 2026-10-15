// node cbor-test.mjs: RFC 8949 Appendix A vectors, round trips, refs and errors, the encode cost of
// 200 D1 rows, and the input files of bench.roc (rows.cbor, rows-arr.cbor, rows-cols.cbor, rows.json).
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { encode, decode } from './cbor.mjs';
import { encode as jsEncode } from '../codec.mjs';

const hex = (u8) => Buffer.from(u8).toString('hex');
const unhex = (h) => new Uint8Array(Buffer.from(h, 'hex'));

// [value, encoding] from RFC 8949 Appendix A, the part in the profile (floats are written as f64).
const vectors = [
  [0, '00'], [1, '01'], [10, '0a'], [23, '17'], [24, '1818'], [25, '1819'], [100, '1864'], [1000, '1903e8'],
  [1000000, '1a000f4240'], [1000000000000, '1b000000e8d4a51000'], [18446744073709551615n, '1bffffffffffffffff'],
  [-18446744073709551616n, '3bffffffffffffffff'], [-1, '20'], [-10, '29'], [-100, '3863'], [-1000, '3903e7'],
  [1.1, 'fb3ff199999999999a'], [-4.1, 'fbc010666666666666'], [false, 'f4'], [true, 'f5'], [null, 'f6'], [undefined, 'f7'],
  ['', '60'], ['a', '6161'], ['IETF', '6449455446'], ['"\\', '62225c'], ['ü', '62c3bc'], ['水', '63e6b0b4'],
  ['\u{10151}', '64f0908591'], [new Uint8Array([1, 2, 3, 4]), '4401020304'], [[], '80'], [[1, 2, 3], '83010203'],
  [[1, [2, 3], [4, 5]], '8301820203820405'],
  [Array.from({ length: 25 }, (_, i) => i + 1), '98190102030405060708090a0b0c0d0e0f101112131415161718181819'],
  [{}, 'a0'], [{ a: 1, b: [2, 3] }, 'a26161016162820203'], [['a', { b: 'c' }], '826161a161626163'],
];
for (const [v, h] of vectors) {
  assert.equal(hex(encode(v)), h, `encode ${String(v)}`);
  assert.deepEqual(decode(unhex(h)), v, `decode ${h}`);
}
// Decode only: other widths of floats, and a long head for a small number.
assert.equal(decode(unhex('f93e00')), 1.5);
assert.equal(decode(unhex('f97bff')), 65504);
assert.equal(decode(unhex('fa47c35000')), 100000);
assert.equal(decode(unhex('f97c00')), Infinity);
assert.equal(decode(unhex('1a00000001')), 1);
// Not in the profile.
assert.throws(() => decode(unhex('9f0102ff')), /indefinite/);
assert.throws(() => decode(unhex('c11a514b67b0')), /tag 1/);
assert.throws(() => decode(unhex('8301')), /end of input/);
assert.throws(() => decode(unhex('0101')), /trailing/);
assert.throws(() => encode(1n << 64n), RangeError);
const deep = []; let d = deep; for (let i = 0; i < 70; i++) { const x = []; d.push(x); d = x; }
assert.throws(() => encode(deep), /too deep/);

// A ref and an error: tag 27, a generic object.
class Stream {}
const table = [new Stream()];
const withRef = encode({ body: table[0], e: new TypeError('x') }, (o) => table.indexOf(o));
assert.equal(hex(withRef), 'a264626f6479d81b8263526566006165d81b8365457272' + '6f7269547970654572726f726178');
const back = decode(withRef, (id) => table[id]);
assert.equal(back.body, table[0]);
assert.equal(back.e.name, 'TypeError');

// Key reuse: the second map has other keys of the same length at the same places.
assert.deepEqual(decode(encode([{ ab: 1, cd: 2 }, { ab: 3, ce: 4 }, { xy: 5 }])), [{ ab: 1, cd: 2 }, { ab: 3, ce: 4 }, { xy: 5 }]);

// Non-ASCII text past the fast path keeps the right head.
const long = 'é'.repeat(200);
assert.equal(decode(encode(long)), long);
console.log(`cbor: ${vectors.length} RFC vectors and 13 other checks pass`);

// 200 D1 rows, the same rows as ../bench/main.roc.
const h = 'A'.repeat(44);
const cols = ['grp', 'version', 'hash', 'url', 'published_at', 'log_index', 'yanked', 'provenance'];
const arrays = Array.from({ length: 200 }, (_, i) => ['roc-lang/http', `1.${i}.0`, h, `https://github.com/roc-lang/http/releases/download/1.${i}.0/${h}.tar.zst`, 1760000000 + i, 184000 + i, 0, '{"workflow":"release.yml"}']);
const objects = arrays.map((r) => Object.fromEntries(cols.map((c, i) => [c, r[i]])));

const time = (f) => {
  let best = Infinity;
  for (let r = 0; r < 7; r++) { const t0 = process.hrtime.bigint(); for (let i = 0; i < 300; i++) f(); best = Math.min(best, Number(process.hrtime.bigint() - t0) / 300 / 1000); }
  return best.toFixed(1);
};
const json = JSON.stringify(objects);
const te = new TextEncoder();
console.log('JS encode of 200 rows, best of 7 rounds of 300 (µs):');
console.table({
  'Js byte format, objects': time(() => jsEncode(objects)),
  'Js byte format, arrays': time(() => jsEncode(arrays)),
  'CBOR, objects': time(() => encode(objects)),
  'CBOR, arrays': time(() => encode(arrays)),
  'CBOR, [columns, ...arrays]': time(() => encode([cols, ...arrays])),
  'JSON.stringify + TextEncoder, objects': time(() => te.encode(JSON.stringify(objects))),
});
const cborObjects = encode(objects).slice(), jsonBytes = te.encode(json), td = new TextDecoder();
console.log('JS decode of the same 200 rows (µs):');
console.table({
  'CBOR, objects': time(() => decode(cborObjects)),
  'TextDecoder + JSON.parse, objects': time(() => JSON.parse(td.decode(jsonBytes))),
});
writeFileSync(new URL('./rows.cbor', import.meta.url), encode(objects));
writeFileSync(new URL('./rows-arr.cbor', import.meta.url), encode(arrays));
writeFileSync(new URL('./rows-cols.cbor', import.meta.url), encode([cols, ...arrays]));
writeFileSync(new URL('./rows.json', import.meta.url), json);
console.log(`rows.cbor ${encode(objects).length} B, rows-arr.cbor ${encode(arrays).length} B, rows.json ${json.length} B`);
