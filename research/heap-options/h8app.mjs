// H8: request sizes of the bench app (instrumented host), and the waste of each size class.
import { readFileSync } from 'node:fs';
import { makeRunner } from '../bench/core.js';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const r = makeRunner(mod, 'b', io);
let id = 1;
for (let round = 0; round < 10; round++)
  await Promise.all(Array.from({ length: 64 }, (_, i) => r.run(`${id++} 0 ${[5, 30, 100][i % 3]} ${[10, 200, 1000][(i >> 2) % 3]}`)));
const x = r.x;
const h = new Uint32Array(x.memory.buffer, x.hist_ptr(), 513);
const CL = [16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096];
const rows = new Map(); let total = 0, req = 0, cap = 0;
for (let b = 0; b < 513; b++) {
  if (!h[b]) continue;
  const len = b * 16 + 8; // bucket middle
  const t = Math.ceil((16 + len) / 16) * 16;
  const c = CL.find((c) => c >= t) ?? 'large';
  const k = c === 'large' ? 'large' : c;
  const cc = c === 'large' ? t : c;
  const w = rows.get(k) ?? { n: 0, req: 0, cap: 0 };
  w.n += h[b]; w.req += h[b] * (16 + len); w.cap += h[b] * cc; rows.set(k, w);
  total += h[b]; req += h[b] * (16 + len); cap += h[b] * cc;
}
for (const [k, w] of rows) console.log(k, 'n', w.n, `${(100 * w.n / total).toFixed(1)}%`, 'waste', `${(100 * (w.cap - w.req) / w.cap).toFixed(1)}%`);
console.log('all: n', total, 'waste', `${(100 * (cap - req) / cap).toFixed(1)}%`, 'bytes requested MB', (req / 1048576).toFixed(1));
