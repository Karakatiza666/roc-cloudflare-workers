// The largest functions of a wasm (code body bytes), by the name section. Usage: node sizes.mjs <wasm> [n] [filter]
import { readFileSync } from 'node:fs';
const b = readFileSync(process.argv[2]); const N = Number(process.argv[3] ?? 25); const filt = process.argv[4];
let p = 8; const leb = () => { let r = 0, s = 0, x; do { x = b[p++]; r |= (x & 127) << s; s += 7; } while (x & 128); return r >>> 0; };
let imports = 0, bodies = [], names = new Map();
while (p < b.length) {
  const id = b[p++]; const len = leb(); const end = p + len;
  if (id === 2) { const n = leb(); for (let i = 0; i < n; i++) { p += leb(); p += leb() ; const k = b[p++]; if (k === 0) { leb(); imports++; } else if (k === 1) { p++; const f = leb(); leb(); if (f & 1) leb(); } else if (k === 2) { const f = leb(); leb(); if (f & 1) leb(); } else { p += 2; } } }
  if (id === 10) { const n = leb(); for (let i = 0; i < n; i++) { const sz = leb(); bodies.push(sz); p += sz; } }
  if (id === 0) { const nl = leb(); const nm = b.subarray(p, p + nl).toString(); p += nl; if (nm === 'name') { while (p < end) { const sid = b[p++]; const sl = leb(); const se = p + sl; if (sid === 1) { const n = leb(); for (let i = 0; i < n; i++) { const idx = leb(); const l = leb(); names.set(idx, b.subarray(p, p + l).toString()); p += l; } } p = se; } } }
  p = end;
}
let rows = bodies.map((s, i) => [s, names.get(i + imports) ?? `#${i + imports}`]);
if (filt) rows = rows.filter((r) => r[1].includes(filt));
const total = rows.reduce((a, r) => a + r[0], 0);
console.log('functions', rows.length, 'code bytes', total);
rows.sort((a, c) => c[0] - a[0]).slice(0, N).forEach(([s, n]) => console.log(String(s).padStart(8), n.slice(0, 150)));
