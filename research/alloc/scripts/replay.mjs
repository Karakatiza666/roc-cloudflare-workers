// Run a trace (scripts/trace.mjs) against replay builds (replay/build.sh).
// node replay.mjs <trace name, e.g. 2000_6> [reps=5] <versions>...
// A version can carry setters: 'v5:set_large_min_run=8,set_place=0'.
// Per version: the median replay time of `reps` fresh instances without sums (ms,
// ns per call), then with the sum at each wait (msSum), then also a check at each
// resume (msCheck, sum mode 2; `bad` counts sums that differ), memory grown, peak of pages,
// KB summed per wait.
import { readFileSync } from 'node:fs';
const [name, reps0, ...vers] = process.argv.slice(2);
const reps = Number(reps0);
const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
let calls = 0, waits = 0;
for (let i = 0; i < tr.length; i += 4) { const k = tr[i] & 0xff; if (k <= 3) calls++; if (k === 5) waits++; }
const CH = 1 << 16;
const rows = [];
for (const v of vers) {
  const [file, sets = ''] = v.split(':');
  const mod = new WebAssembly.Module(readFileSync(new URL(`../out/replay_${file}.wasm`, import.meta.url)));
  const once = (sum) => {
    const x = new WebAssembly.Instance(mod, {}).exports;
    x.set_sum(sum);
    for (const kv of sets.split(',').filter(Boolean)) { const [k, val] = kv.split('='); x[k](Number(val)); }
    const mem0 = x.memory.buffer.byteLength;
    const rb = x.rec_buf();
    let ms = 0;
    for (let i = 0; i < tr.length; i += CH * 4) {
      const part = tr.subarray(i, Math.min(tr.length, i + CH * 4));
      new Uint32Array(x.memory.buffer, rb, part.length).set(part);
      const t = performance.now();
      x.run(part.length / 4);
      ms += performance.now() - t;
    }
    return { ms, bad: x.sum_mismatch(), mem: (x.memory.buffer.byteLength - mem0) / 2 ** 20, peak: x.pages_peak() / 2 ** 20, sum: x.sum_bytes(), copyMB: x.copy_bytes() / 2 ** 20, copies: x.copies(), endKB: x.pages_used() / 1024, liveEndKB: x.live_bytes() / 1024, smallPages: x.small_pages_taken?.() ?? '', inPlace: x.grown_in_place?.() ?? '' };
  };
  const med = (sum) => {
    const res = Array.from({ length: reps }, () => once(sum)).sort((a, b) => a.ms - b.ms);
    return { ...res[reps >> 1], min: res[0].ms };
  };
  // A version that traps (out of memory) gets a row with the trap.
  try { once(0); } catch (e) { rows.push({ v, ms: `trap: ${e.message}` }); continue; } // warm-up: the wasm tier-up is not timed
  const m = med(0), s = med(1), c = med(2);
  rows.push({ v, ms: +m.ms.toFixed(1), msMin: +m.min.toFixed(1), nsPerCall: +((m.ms * 1e6) / calls).toFixed(1), msSum: +s.ms.toFixed(1), msCheck: +c.ms.toFixed(1), bad: c.bad, memMB: +m.mem.toFixed(1), pagesPeakMB: +m.peak.toFixed(1), sumKBperWait: +(s.sum / waits / 1024).toFixed(0), copies: m.copies, copyMB: +m.copyMB.toFixed(0), smallPages: m.smallPages, inPlace: m.inPlace, pagesEndKB: m.endKB, liveEndKB: m.liveEndKB });
}
console.log(`trace ${name}: ${calls} calls, ${waits} waits`);
console.table(rows);
