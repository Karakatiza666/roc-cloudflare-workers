// Memory and copies of replay versions on traces: peak of pages, memory grown, copies, KB copied, sums that differ (sum mode 2).
// node regpeak.mjs <versions, comma separated, setters as replay.mjs> <trace names>...
import { readFileSync } from 'node:fs';
const [vers, ...names] = process.argv.slice(2);
const rows = [];
for (const t of names) {
  const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${t}.bin`, import.meta.url)).buffer.slice(0));
  for (const v of vers.split(',')) {
    const [f, sets = ''] = v.split(':');
    const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(new URL(`../out/replay_${f}.wasm`, import.meta.url))), {}).exports;
    x.set_sum(2);
    for (const kv of sets.split(';').filter(Boolean)) { const [k, val] = kv.split('='); x[k](Number(val)); }
    const m0 = x.memory.buffer.byteLength, rb = x.rec_buf();
    for (let i = 0; i < tr.length; i += 4 << 16) { const p = tr.subarray(i, Math.min(tr.length, i + (4 << 16))); new Uint32Array(x.memory.buffer, rb, p.length).set(p); x.run(p.length / 4); }
    rows.push({ trace: t, v, peakKB: x.pages_peak() / 1024, memKB: (x.memory.buffer.byteLength - m0) / 1024, copies: x.copies(), copyKB: Math.round(x.copy_bytes() / 1024), bad: x.sum_mismatch() & 0xffff, liveEnd: x.live_bytes() });
  }
}
console.table(rows);
