import { readFileSync } from 'node:fs';
import { makeRunner } from './bench/core.js';
const r = makeRunner(new WebAssembly.Module(readFileSync('out/app_v.wasm')), 'b', async () => 'x', { noFallback: true });
for (const q of process.argv.slice(2)) {
  const x = r.x;
  const res = await r.run(q);
  console.log(q, res.body !== undefined ? `body ${res.body.length} B` : res.trap.slice(0, 40), 'sp', x.sp_at_abort() >>> 0, 'mem MB', (x.memory.buffer.byteLength / 2 ** 20).toFixed(1), 'live MB', (x.live_bytes() / 2 ** 20).toFixed(2));
}
