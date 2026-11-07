// Placement check: two replay builds give the same address to each alloc and realloc of a trace.
// node same.mjs <trace name> <version a> <version b>   (a version can carry setters, as in replay.mjs)
// The pool starts at a different address when the static data differs, so the addresses must differ by one fixed amount.
// Prints the first record that differs, or "same" with the count of records. Exit 1 when they differ.
import { readFileSync } from 'node:fs';
const [name, ...vers] = process.argv.slice(2);
const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
const inst = (v) => {
  const [file, sets = ''] = v.split(':');
  const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(new URL(`../out/replay_${file}.wasm`, import.meta.url))), {}).exports;
  x.set_sum(2);
  for (const kv of sets.split(',').filter(Boolean)) { const [k, val] = kv.split('='); x[k](Number(val)); }
  return { x, rb: x.rec_buf() };
};
const [a, b] = vers.map(inst);
let n = 0, delta = null;
for (let i = 0; i < tr.length; i += 4) {
  const rec = tr.subarray(i, i + 4);
  for (const s of [a, b]) { new Uint32Array(s.x.memory.buffer, s.rb, 4).set(rec); s.x.run(1); }
  const k = rec[0] & 0xff;
  if (k === 1 || k === 3) {
    n++;
    const pa = a.x.ptr_of(rec[2]), pb = b.x.ptr_of(rec[2]);
    if (delta === null && pa && pb) delta = pa - pb;
    if (pa - pb !== delta && !(pa === 0 && pb === 0)) { console.log(`${name}: differ at record ${i / 4} (op ${k}, id ${rec[2]}, len ${rec[3]}): ${vers[0]} ${pa}, ${vers[1]} ${pb}`); process.exit(1); }
  }
}
const ok = a.x.sum_mismatch() === b.x.sum_mismatch() && a.x.pages_peak() === b.x.pages_peak() && a.x.live_bytes() === b.x.live_bytes();
console.log(`${name}: ${ok ? 'same' : 'differ in end state'} (${n} allocs and reallocs; peak pages ${a.x.pages_peak()} ${b.x.pages_peak()}; bad ${a.x.sum_mismatch() & 0xffff} ${b.x.sum_mismatch() & 0xffff})`);
process.exit(ok ? 0 : 1);
