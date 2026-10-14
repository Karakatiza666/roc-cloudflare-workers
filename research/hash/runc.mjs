import { readFileSync } from 'node:fs';
const { instance } = await WebAssembly.instantiate(readFileSync('c.wasm'));
const x = instance.exports; x.fill();
const rows = [];
for (const len of [65536, 300 * 1024, 1 << 20, 10 << 20, 30 << 20]) {
  const r = { KB: len / 1024 };
  for (const f of ['xorv', 'fletch', 'wy']) {
    // Use a different 10 MB window each time for the large sizes, so the cache does not help.
    const iters = Math.max(5, Math.floor((256 << 20) / len));
    x[f](len);
    const t = [];
    for (let k = 0; k < 5; k++) { const s = performance.now(); for (let j = 0; j < iters; j++) x[f](len); t.push((performance.now() - s) / iters * 1000); }
    t.sort((a, b) => a - b);
    r[`${f} µs`] = +t[2].toFixed(1);
    r[`${f} GB/s`] = +(len / (t[2] * 1e3)).toFixed(1);
  }
  rows.push(r);
}
console.table(rows);
// Detection: one flipped bit, and a swap of two different words.
const n = 1 << 20;
for (const f of ['xorv', 'fletch', 'wy']) {
  const h0 = x[f](n);
  x.flip(12345); const h1 = x[f](n); x.flip(12345);
  x.swap(1024, 4096); const h2 = x[f](n); x.swap(1024, 4096);
  console.log(f, 'bit flip found:', h1 !== h0, '| swap found:', h2 !== h0, '| restored:', x[f](n) === h0);
}
