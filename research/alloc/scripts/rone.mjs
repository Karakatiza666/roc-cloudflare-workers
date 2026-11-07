// One process for scripts/pstat.mjs: warm up a replay module, then run the trace `runs` times.
// node rone.mjs <trace> <version[:setters]> <sum mode> <runs>
import { readFileSync } from 'node:fs';
const [name, v, sum0, runs0] = process.argv.slice(2);
const [file, sets = ''] = v.split(':');
const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
const mod = new WebAssembly.Module(readFileSync(new URL(`../out/replay_${file}.wasm`, import.meta.url)));
const CH = 1 << 16;
const once = () => {
  const x = new WebAssembly.Instance(mod, {}).exports;
  x.set_sum(Number(sum0));
  for (const kv of sets.split(',').filter(Boolean)) { const [k, val] = kv.split('='); x[k](Number(val)); }
  const rb = x.rec_buf();
  for (let i = 0; i < tr.length; i += CH * 4) {
    const part = tr.subarray(i, Math.min(tr.length, i + CH * 4));
    new Uint32Array(x.memory.buffer, rb, part.length).set(part);
    x.run(part.length / 4);
  }
};
// Warm-up as the timed runs: the same tier-up in both processes.
for (let r = 0; r < 3 + Number(runs0); r++) once();
