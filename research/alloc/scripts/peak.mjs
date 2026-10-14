// Memory, peak of pages and live data after 50 batches of 64 requests (2,000 items).
// node peak.mjs <version>... (each in this process). Env ID0: first request id. PLACE: set_place value
// (when not set, each version keeps its own default).
import { readFileSync } from 'node:fs';
import { makeRunner, check } from '../harness/bench/core.js';
const wasm = (name) => readFileSync(new URL(`../out/${name}.wasm`, import.meta.url));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
let id = Number(process.env.ID0 ?? 1);
for (const f of process.argv.slice(2)) {
  const r = makeRunner(new WebAssembly.Module(wasm(`app_${f}`)), 'b', io);
  r.x.set_sum(0); if (process.env.PLACE) r.x.set_place?.(Number(process.env.PLACE));
  for (let b = 0; b < 50; b++) await Promise.all(Array.from({ length: 64 }, () => r.run(`${id++} 0 50 2000`)));
  const h = Array.from({ length: 8 }, (_, i) => r.x.large_hist?.(i));
  console.log(f, 'mem MB', (r.x.memory.buffer.byteLength / 2 ** 20).toFixed(1), 'pages peak MB', ((r.x.heap_peak?.() ?? 0) / 2 ** 20).toFixed(1), 'live peak MB', ((r.x.live_peak?.() ?? 0) / 2 ** 20).toFixed(1), 'large by 2^(12+i):', h.join(' '));
}
