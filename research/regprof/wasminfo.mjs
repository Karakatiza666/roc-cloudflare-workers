// Sections of a wasm file: imported functions, defined functions, body sizes, custom sections,
// and function names from a "name" section or from the symbol table of a "linking" section (an object file).
// node wasminfo.mjs <file.wasm> [--bodies]    Library: import { wasmInfo } from './wasminfo.mjs'
import { readFileSync } from 'node:fs';
export function wasmInfo(buf) {
  let p = 0;
  const u8 = () => buf[p++];
  const leb = () => { let r = 0, s = 0, b; do { b = buf[p++]; r += (b & 0x7f) * 2 ** s; s += 7; } while (b & 0x80); return r; };
  const str = () => { const n = leb(); const s = buf.toString('utf8', p, p + n); p += n; return s; };
  p = 8;
  const out = { importFuncs: 0, imports: [], bodies: [], custom: [], names: new Map(), exports: [] };
  while (p < buf.length) {
    const id = u8(); const size = leb(); const end = p + size;
    if (id === 0) {
      const name = str(); out.custom.push({ name, size });
      if (name === 'name') {
        while (p < end) { const sub = u8(); const sz = leb(); const e2 = p + sz; if (sub === 1) { const n = leb(); for (let i = 0; i < n; i++) { const idx = leb(); out.names.set(idx, str()); } } p = e2; }
      } else if (name === 'linking') {
        leb(); // version
        while (p < end) {
          const sub = u8(); const sz = leb(); const e2 = p + sz;
          if (sub === 8) { // symbol table
            const n = leb();
            for (let i = 0; i < n; i++) {
              const kind = u8(); const flags = leb();
              if (kind === 0 || kind === 2 || kind === 4 || kind === 5) { // func, global, event, table
                const idx = leb(); const undef = flags & 0x10; const explicit = flags & 0x40;
                let nm = null; if (!undef || explicit) nm = str();
                if (kind === 0 && nm !== null && !undef) out.names.set(idx, nm);
              } else if (kind === 1) { const nm = str(); if (!(flags & 0x10)) { leb(); leb(); leb(); } }
              else if (kind === 3) leb();
            }
          }
          p = e2;
        }
      }
    } else if (id === 2) {
      const n = leb();
      for (let i = 0; i < n; i++) { const mod = str(); const nm = str(); const k = u8(); if (k === 0) { leb(); out.imports.push(`${mod}.${nm}`); out.importFuncs++; } else if (k === 1) { u8(); const f = leb(); leb(); if (f & 1) leb(); } else if (k === 2) { const f = leb(); leb(); if (f & 1) leb(); } else if (k === 3) { u8(); u8(); } else if (k === 4) { u8(); leb(); } }
    } else if (id === 7) {
      const n = leb();
      for (let i = 0; i < n; i++) { const nm = str(); const k = u8(); const idx = leb(); if (k === 0) out.exports.push([nm, idx]); }
    } else if (id === 10) {
      const n = leb();
      for (let i = 0; i < n; i++) { const sz = leb(); out.bodies.push({ off: p, size: sz }); p += sz; }
    }
    p = end;
  }
  return out;
}
if (import.meta.url === `file://${process.argv[1]}`) {
  const i = wasmInfo(readFileSync(process.argv[2]));
  console.log({ importFuncs: i.importFuncs, defined: i.bodies.length, custom: i.custom, names: i.names.size, exports: i.exports.length });
  const big = i.bodies.map((b, k) => [k + i.importFuncs, b.size]).sort((a, b) => b[1] - a[1]).slice(0, 8);
  console.log('largest bodies [index, bytes]:', big.map(([k, s]) => `${k}:${s}${i.names.has(k) ? ' ' + i.names.get(k) : ''}`).join(', '));
}
