// V1/V2: the stack pointer that task_abort reads after each trap.
import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const dir = process.argv[2];
const rows = [];
async function one(file, req) {
  const m = new WebAssembly.Module(readFileSync(`${dir}/${file}`));
  const r = makeRunner(m, 'b', async () => 'x', { noFallback: true });
  const x = r.x;
  const res = await r.run(req);
  const mem = x.memory.buffer.byteLength;
  const sp = x.sp_at_abort() >>> 0;
  const cb = x.canary_base() >>> 0;
  const kind = res.body !== undefined ? 'body' : res.trap.slice(0, 40);
  const inRange = res.body === undefined ? (sp < cb ? 'below CANARY_BASE' : sp >= mem ? 'above memory' : 'in stack') : '';
  rows.push({ file, req, kind, sp, cb, mem, inRange, retired: r.stats.retired });
}
for (const d of [4400, 4500, 4600, 4700, 5000, 5500, 6000, 7000, 8000, 10000, 12000, 15000, 20000, 30000])
  for (const a of ['', ' alloc']) await one('app_deep.wasm', `${d}${a}`);
for (const k of [99, 98]) for (const d of [0, 10, 100, 1000]) await one('app_v.wasm', `${k} ${d}`);
for (let d = 1000; d <= 40000; d += 1000) await one('app_v.wasm', `2 ${d}`);
console.table(rows);
