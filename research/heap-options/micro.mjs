// ns per alloc+free pair (h_bench: k allocs then k frees; h_bench_mixed: random sizes 8..2007, shuffled frees),
// and ns per span of one reclaim walk. node micro.mjs <variant>...
import { readFileSync } from 'node:fs';
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
const time = (f) => { const t = performance.now(); f(); return performance.now() - t; };
for (const v of process.argv.slice(2)) {
  const x = (await WebAssembly.instantiate(readFileSync(new URL(`out/${v}.wasm`, import.meta.url)))).instance.exports;
  const out = { v };
  for (const size of [24, 200, 3000, 20000]) {
    const n = size > 4096 ? 2000 : 20000;
    x.h_bench(200, 64, size);
    out['s' + size] = +med(Array.from({ length: 7 }, () => (time(() => x.h_bench(n, 64, size)) * 1e6) / (n * 64))).toFixed(2);
  }
  x.h_bench_mixed(200, 200, 7);
  out.mixed = +med(Array.from({ length: 7 }, (_, i) => (time(() => x.h_bench_mixed(2000, 200, 11 + i)) * 1e6) / (2000 * 200))).toFixed(2);
  console.log(JSON.stringify(out));
}
// Walk: 100k spans, every other one free.
{
  const x = (await WebAssembly.instantiate(readFileSync(new URL(`out/h1.wasm`, import.meta.url)))).instance.exports;
  const ps = []; for (let i = 0; i < 100000; i++) ps.push(x.h_alloc(40 + (i % 7) * 16, 1));
  for (let i = 0; i < ps.length; i += 2) x.h_free(ps[i]);
  const us = med(Array.from({ length: 9 }, () => time(() => x.h_walk()) * 1000));
  console.log(JSON.stringify({ walk: '100k spans, half free', heapMB: +((x.h_end() - x.h_start()) / 1048576).toFixed(1), us: +us.toFixed(0), nsPerSpan: +(us * 1000 / 100000).toFixed(2) }));
}
