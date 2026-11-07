// Compare replay CPU of versions on a shared (noisy) machine: the runs of all versions are
// interleaved (a round runs each version once, in a turned order), so a slow period hits all.
// node rcmp.mjs <trace> <rounds> <sum modes, e.g. 0,2> <versions>...   (a version can carry setters as in replay.mjs)
// Prints per version and sum mode: median ms, the spread p25 to p75, min, and the median
// of (ms - ms of the first version) in the same round, with its p25 to p75.
import { readFileSync } from 'node:fs';
const [name, rounds0, modes0, ...vers] = process.argv.slice(2);
const rounds = Number(rounds0);
const modes = modes0.split(',').map(Number);
const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
const CH = 1 << 16;
const mods = vers.map((v) => {
  const [file, sets = ''] = v.split(':');
  return { v, sets, mod: new WebAssembly.Module(readFileSync(new URL(`../out/replay_${file}.wasm`, import.meta.url))) };
});
const once = ({ mod, sets }, sum) => {
  const x = new WebAssembly.Instance(mod, {}).exports;
  x.set_sum(sum);
  for (const kv of sets.split(',').filter(Boolean)) { const [k, val] = kv.split('='); x[k](Number(val)); }
  const rb = x.rec_buf();
  let ms = 0;
  for (let i = 0; i < tr.length; i += CH * 4) {
    const part = tr.subarray(i, Math.min(tr.length, i + CH * 4));
    new Uint32Array(x.memory.buffer, rb, part.length).set(part);
    const t = performance.now();
    x.run(part.length / 4);
    ms += performance.now() - t;
  }
  if (sum === 2 && x.sum_mismatch() !== 0) throw new Error(`${sets} sums differ: ${x.sum_mismatch()}`);
  return ms;
};
for (const m of mods) for (const s of modes) { once(m, s); once(m, s); } // tier-up
const t = mods.map(() => modes.map(() => []));
for (let r = 0; r < rounds; r++) {
  for (let k = 0; k < mods.length; k++) {
    const i = (k + r) % mods.length;
    modes.forEach((s, j) => t[i][j].push(once(mods[i], s)));
  }
}
const q = (a, p) => { const b = [...a].sort((x, y) => x - y); return b[Math.min(b.length - 1, Math.floor(p * b.length))]; };
const f = (x) => x.toFixed(1);
const rows = [];
mods.forEach((m, i) => modes.forEach((s, j) => {
  const a = t[i][j];
  const d = a.map((x, r) => x - t[0][j][r]);
  rows.push({ v: m.v, sum: s, med: +f(q(a, 0.5)), p25_p75: `${f(q(a, 0.25))}..${f(q(a, 0.75))}`, min: +f(Math.min(...a)), dMed: +f(q(d, 0.5)), dP25_p75: `${f(q(d, 0.25))}..${f(q(d, 0.75))}` });
}));
console.log(`trace ${name}, ${rounds} rounds`);
console.table(rows);
