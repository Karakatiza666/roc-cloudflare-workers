// node mkwasm.mjs <pages> <out>: (import env.get) (memory pages) run() calls get; exports run, mem.
import { writeFileSync } from 'node:fs';
const [pages, out] = process.argv.slice(2);
const leb = (n) => { const b = []; do { let x = n & 0x7f; n >>>= 7; if (n) x |= 0x80; b.push(x); } while (n); return b; };
const sec = (id, c) => [id, ...leb(c.length), ...c];
const bytes = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
  ...sec(1, [1, 0x60, 0, 1, 0x7f]),
  ...sec(2, [1, 3, 0x65, 0x6e, 0x76, 3, 0x67, 0x65, 0x74, 0, 0]),
  ...sec(3, [1, 0]),
  ...sec(5, [1, 0, ...leb(Number(pages))]),
  ...sec(7, [2, 3, 0x72, 0x75, 0x6e, 0, 1, 3, 0x6d, 0x65, 0x6d, 2, 0]),
  ...sec(10, [1, 4, 0, 0x10, 0, 0x0b])];
writeFileSync(out, Uint8Array.from(bytes));
new WebAssembly.Module(Uint8Array.from(bytes));
