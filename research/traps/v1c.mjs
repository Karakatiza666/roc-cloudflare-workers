// A fresh module per case: does the first request decide the trap kind?
import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const buf = readFileSync('out/app_deep.wasm');
const rows = [];
for (const seq of [['4500'], ['5', '4500'], ['100', '4500'], ['1000', '4500'], ['3000', '4500'], ['4500', '4500'], ['4500 alloc'], ['5', '4500 alloc']]) {
  const r = makeRunner(new WebAssembly.Module(buf), 'b', async () => 'x', { noFallback: true });
  const out = [];
  for (const q of seq) { const x = r.x; const res = await r.run(q); out.push(res.body !== undefined ? 'body' : `${res.trap.slice(0, 20)} sp=${x.sp_at_abort() >>> 0}`); }
  rows.push({ seq: seq.join(' > '), result: out.join(' | ') });
}
console.table(rows);
