import { readFileSync } from 'node:fs';
const { instance } = await WebAssembly.instantiate(readFileSync('h.wasm'));
const x = instance.exports; x.fill();
const rows = [];
for (const len of [4096, 65536, 300 * 1024, 1 << 20]) {
  const r = { KB: len / 1024 };
  for (const f of ['wy', 'xx3', 'crc', 'copy']) {
    const iters = Math.max(20, Math.floor((64 << 20) / len));
    x[f](len, iters);
    const t = [];
    for (let k = 0; k < 5; k++) { const s = performance.now(); x[f](len, iters); t.push((performance.now() - s) / iters * 1000); }
    t.sort((a, b) => a - b);
    r[`${f} µs`] = +t[2].toFixed(2);
    if (f !== 'copy') r[`${f} GB/s`] = +(len / (t[2] * 1e3)).toFixed(2);
  }
  rows.push(r);
}
console.table(rows);
