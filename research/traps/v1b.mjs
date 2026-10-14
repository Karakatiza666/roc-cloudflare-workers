// The kind of trap for a deep request, with cold (Liftoff) and warm (TurboFan) code.
import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const dir = process.argv[2], file = process.argv[3], warmReq = process.argv[4];
const m = new WebAssembly.Module(readFileSync(`${dir}/${file}`));
const rows = [];
for (const warm of [0, 200]) {
  const r = makeRunner(m, 'b', async () => 'x', { noFallback: true });
  for (let i = 0; i < warm; i++) await r.run(warmReq);
  for (const req of process.argv.slice(5)) {
    const x = r.x, ret = r.stats.retired;
    const res = await r.run(req);
    const sp = x.sp_at_abort() >>> 0, mem = x.memory.buffer.byteLength;
    rows.push({ warm, req, kind: res.body !== undefined ? 'body' : res.trap.slice(0, 30), sp, where: res.body !== undefined ? '' : sp < x.canary_base() ? 'below CANARY_BASE' : sp >= mem ? 'above memory' : 'in stack', retired: r.stats.retired - ret });
  }
}
console.table(rows);
