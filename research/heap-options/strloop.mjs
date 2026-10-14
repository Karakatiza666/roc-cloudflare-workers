// The "build a string in a loop" pattern: each step allocates a copy a little larger, then frees the old one.
// node strloop.mjs <n> <stepBytes> [mode=alloc|realloc]
import { readFileSync } from 'node:fs';
const [n, step, mode = 'alloc'] = [Number(process.argv[2]), Number(process.argv[3]), process.argv[4]];
const rows = [];
for (const v of ['base', 'h1', 'h4L1', 'h6', 'h64L1', 'h5']) {
  const { instance } = await WebAssembly.instantiate(readFileSync(new URL(`out/${v}.wasm`, import.meta.url)));
  const x = instance.exports;
  let p = x.h_alloc(16, 1), err = '';
  try {
    for (let i = 1; i <= n; i++) {
      if (mode === 'realloc') p = x.h_realloc(p, 16 + i * step, 1);
      else { const q = x.h_alloc(16 + i * step, 1); x.h_free(p); p = q; }
      if (p === 0) { err = `OOM at ${i}`; break; }
    }
  } catch (e) { err = String(e).slice(0, 30); }
  rows.push({ v, mode, final: 16 + n * step, heapMB: +((x.h_next() - x.h_start()) / 2 ** 20).toFixed(1), memMB: +(x.memory.buffer.byteLength / 2 ** 20).toFixed(1), walks: x.h_walks(), err });
}
console.table(rows);
