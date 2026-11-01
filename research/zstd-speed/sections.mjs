// Section sizes of a wasm. Usage: node sections.mjs <wasm>...
import { readFileSync } from 'node:fs';
for (const f of process.argv.slice(2)) {
  const b = readFileSync(f); let p = 8; const leb = () => { let r = 0, s = 0, x; do { x = b[p++]; r |= (x & 127) << s; s += 7; } while (x & 128); return r >>> 0; };
  const out = {}; while (p < b.length) { const id = b[p++]; const len = leb(); let name = ['custom','type','import','function','table','memory','global','export','start','element','code','data','datacount'][id];
    if (id === 0) { const q = p; const nl = leb(); name = 'custom:' + b.subarray(p, p + nl).toString(); p = q; } out[name] = (out[name] ?? 0) + len; p += len; }
  console.log(f.split('/').pop().padEnd(40), JSON.stringify(out));
}
