// Profile of the allocator CPU in a replay: self time per wasm function (V8 sampling profiler).
// Build the module with names first: ZFLAGS=-fno-strip replay/build.sh v7 (then rename it, e.g. replay_v7_prof).
// node prof.mjs <trace, e.g. 2000_6> <module, e.g. v7_prof> [sum mode=2] [runs=10] [interval µs=50]
// Prints: % of samples in each function (self time), and ms per trace for each.
import { readFileSync } from 'node:fs';
import { Session } from 'node:inspector/promises';
const [name, file, sum0 = '2', runs0 = '10', iv0 = '50'] = process.argv.slice(2);
const [sum, runs, iv] = [sum0, runs0, iv0].map(Number);
const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
const mod = new WebAssembly.Module(readFileSync(new URL(`../out/replay_${file}.wasm`, import.meta.url)));
const CH = 1 << 16;
const once = () => {
  const x = new WebAssembly.Instance(mod, {}).exports;
  x.set_sum(sum);
  const rb = x.rec_buf();
  let ms = 0;
  for (let i = 0; i < tr.length; i += CH * 4) {
    const part = tr.subarray(i, Math.min(tr.length, i + CH * 4));
    new Uint32Array(x.memory.buffer, rb, part.length).set(part);
    const t = performance.now();
    x.run(part.length / 4);
    ms += performance.now() - t;
  }
  return ms;
};
once(); once(); // tier-up
const s = new Session();
s.connect();
await s.post('Profiler.enable');
await s.post('Profiler.setSamplingInterval', { interval: iv });
await s.post('Profiler.start');
let total = 0;
for (let r = 0; r < runs; r++) total += once();
const { profile } = await s.post('Profiler.stop');
const self = new Map();
const byId = new Map(profile.nodes.map((n) => [n.id, n]));
const counts = new Map();
for (const id of profile.samples) counts.set(id, (counts.get(id) ?? 0) + 1);
let all = 0;
for (const [id, c] of counts) {
  const n = byId.get(id);
  let f = n.callFrame.functionName || '(anon)';
  if (!n.callFrame.url.startsWith('wasm')) f = `[js] ${f}`;
  self.set(f, (self.get(f) ?? 0) + c);
  all += c;
}
const wasmAll = [...self].filter(([f]) => !f.startsWith('[js]') && !f.startsWith('(')).reduce((a, [, c]) => a + c, 0);
const perTrace = total / runs;
console.log(`trace ${name}, ${file}, sum ${sum}: ${perTrace.toFixed(1)} ms per trace (${runs} runs), ${all} samples, wasm ${wasmAll}`);
const rows = [...self].sort((a, b) => b[1] - a[1]).filter(([, c]) => c / all >= 0.003)
  .map(([f, c]) => ({ fn: f.slice(0, 60), pct: +((100 * c) / all).toFixed(1), msPerTrace: +((perTrace * c) / wasmAll).toFixed(2) }));
console.table(rows);
