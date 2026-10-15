// node codec-test.mjs: the JS codec gives the same bytes as Js.roc, and the encode cost of D1 results.
import { encode, decode } from './codec.mjs';
import assert from 'node:assert/strict';

// Same bytes as the Js.roc expect: Text("hi").
assert.deepEqual([...encode('hi')], [6, 2, 0, 0, 0, 104, 105]);
const refs = [];
const v = { results: [['roc-lang/http', -3n, 1.5, null, true]], bytes: new Uint8Array([0, 255, 128]), stream: new Map(), meta: { changes: 2n ** 63n - 1n } };
const back = decode(encode(v, (o) => refs.push(o) - 1 + 7), (id) => refs[id - 7]);
assert.equal(back.stream, v.stream);
assert.deepEqual(back.results, v.results);
assert.deepEqual(back.bytes, v.bytes);
console.log('round trip: pass');

// D1 `.all()` shape: rows as objects. And `.raw()`: rows as arrays.
const row = (i) => ({ grp: 'roc-lang/http', version: `1.${i}.0`, hash: 'A'.repeat(44), url: `https://github.com/roc-lang/http/releases/download/1.${i}.0/${'A'.repeat(44)}.tar.zst`, published_at: 1760000000 + i, log_index: 184000 + i, yanked: 0, provenance: '{"workflow":"release.yml"}' });
for (const n of [20, 200, 2000]) {
  const all = { results: Array.from({ length: n }, (_, i) => row(i)), success: true, meta: { duration: 0.2, rows_read: n } };
  const raw = [Object.keys(row(0)), ...all.results.map(Object.values)];
  for (const [name, val] of [['all', all], ['raw', raw]]) {
    for (let i = 0; i < 200; i++) encode(val);
    const reps = 2000, t = performance.now();
    let bytes = 0;
    for (let i = 0; i < reps; i++) bytes = encode(val).length;
    const us = ((performance.now() - t) * 1000) / reps;
    console.log(`${n} rows ${name}: ${bytes} B, encode ${us.toFixed(1)} µs, ${(us * 1000 / n).toFixed(0)} ns per row`);
  }
}

// Baseline: JSON text, the other way to send the same rows.
const te = new TextEncoder();
for (const n of [200, 2000]) {
  const raw = [Object.keys(row(0)), ...Array.from({ length: n }, (_, i) => Object.values(row(i)))];
  for (let i = 0; i < 200; i++) te.encode(JSON.stringify(raw));
  const reps = 2000, t = performance.now();
  for (let i = 0; i < reps; i++) te.encode(JSON.stringify(raw));
  console.log(`${n} rows raw as JSON text: encode ${(((performance.now() - t) * 1000) / reps).toFixed(1)} µs`);
}
