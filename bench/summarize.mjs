// Markdown tables from the bench.mjs output: node bench/summarize.mjs results.jsonl [leak.jsonl]
// Each cell is the median over the reps; errors and bad responses are summed.
import { readFileSync } from 'node:fs';

const rows = (f) => readFileSync(f, 'utf8').split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l));
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
const kb = (b) => (b / 1024).toFixed(0);

const all = rows(process.argv[2]);
const runs = all.filter((r) => r.conc);
const groups = new Map();
for (const r of runs) {
  const k = `${r.variant}|${r.depth}|${r.conc}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
}
const name = { j: 'JS only', a: 'A', b: 'B' };
console.log('| Variant | Depth | Copy/wait KB | Conc | p50 ms | p99 ms | req/s | Errors+bad | Peak held copies KB | wasm memory MB | Reps |');
console.log('|---|---|---|---|---|---|---|---|---|---|---|');
for (const [, g] of groups) {
  const r = g[0];
  console.log(`| ${name[r.variant]} | ${r.variant === 'j' ? '-' : r.depth} | ${r.variant === 'b' ? kb(Math.max(...g.map((x) => x.savedMax))) : '-'} | ${r.conc} | ${med(g.map((x) => x.p50))} | ${med(g.map((x) => x.p99))} | ${med(g.map((x) => x.rps))} | ${g.reduce((s, x) => s + x.errors + x.bad, 0)} | ${r.variant === 'b' ? kb(Math.max(...g.map((x) => x.savedPeak))) : '-'} | ${r.memBytes ? (Math.max(...g.map((x) => x.memBytes)) / 1048576).toFixed(1) : '-'} | ${g.length} |`);
}
const ends = all.filter((r) => r.rssEndKB);
console.log('\n| Variant | RSS start MB | RSS after warmup MB | RSS end MB | Instance us | Padded instance us |');
console.log('|---|---|---|---|---|---|');
for (const v of ['j', 'a', 'b']) {
  const g = ends.filter((r) => r.variant === v);
  if (!g.length) continue;
  const mb = (f) => g.map((r) => (r[f] / 1024).toFixed(0)).join(' / ');
  const inst = (f) => (g[0][f] ? g.map((r) => r[f]).join(' / ') : '-');
  console.log(`| ${name[v]} | ${mb('rssStartKB')} | ${mb('rssWarmKB')} | ${v === 'a' ? g.map((r) => `${(r.rssEndKB / 1024).toFixed(0)} (after /inst)`).join(' / ') : mb('rssEndKB')} | ${inst('instUs')} | ${inst('instPadUs')} |`);
}
if (process.argv[3]) {
  console.log('\n| Variant | Trap rate | Requests | Traps | Errors+bad | live_bytes before -> after | wasm memory MB before -> after | RSS MB before -> after |');
  console.log('|---|---|---|---|---|---|---|---|');
  for (const r of rows(process.argv[3])) {
    const live = r.variant === 'b' ? `${r.before.live_bytes} -> ${r.after.live_bytes}` : '- (instance dropped)';
    console.log(`| ${name[r.variant]} | ${r.trapRate} | ${r.n} | ${r.traps} | ${r.errors + r.bad} | ${live} | ${(r.before.mem / 1048576).toFixed(1)} -> ${(r.after.mem / 1048576).toFixed(1)} | ${(r.rssBeforeKB / 1024).toFixed(0)} -> ${(r.rssAfterKB / 1024).toFixed(0)} |`);
  }
}
