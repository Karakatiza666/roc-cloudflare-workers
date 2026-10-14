import { readFileSync } from 'node:fs';
import { makeRunner } from '../harness/bench/core.js';
const wasm = (name) => readFileSync(new URL(`../out/${name}.wasm`, import.meta.url));
// The string loop (B5). node strloop.mjs <version> '<kind> <depth> <steps>'...
const r = makeRunner(new WebAssembly.Module(wasm(`app_v_${process.argv[2]}`)), 'b', async () => 'x', { noFallback: true });
for (const q of process.argv.slice(3)) {
  const x = r.x;
  const res = await r.run(q);
  console.log(q, res.body !== undefined ? `body ${res.body.length} B` : res.trap.slice(0, 40), 'sp', x.sp_at_abort() >>> 0, 'mem MB', (x.memory.buffer.byteLength / 2 ** 20).toFixed(1), 'live MB', (x.live_bytes() / 2 ** 20).toFixed(2));
}
