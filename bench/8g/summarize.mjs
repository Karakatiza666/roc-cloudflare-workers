// PLAN.md step 8g: Markdown tables from the JSON lines of one or more runs of `run-node.mjs` or `run-mf.mjs` (the same
// runtime). Each cell: the median over the runs of the median of each run, then min to max over the runs.
//   node bench/8g/summarize.mjs run1.txt run2.txt run3.txt
import { readFileSync } from 'node:fs';
import { median, round } from './lib.mjs';

const runs = process.argv.slice(2).map((f) =>
  readFileSync(f, 'utf8').split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l)),
);
const infos = runs.map((r) => r.find((o) => o.info)?.info);
console.log(`Runs: ${runs.length}. ${infos[0]?.runtime}, ${infos[0]?.cpu}, resumeCheck ${infos[0]?.resumeCheck}. Load average at the start of each run: ${infos.map((i) => i?.load?.[0]).join(', ')}.`);
const cases = new Map();
for (const r of runs) for (const o of r) if (o.group) {
  const key = `${o.group}|${o.name}`;
  if (!cases.has(key)) cases.set(key, { group: o.group, name: o.name, us: [], N: o.N });
  cases.get(key).us.push(o.us);
}
const cell = (xs, d = 1) => (xs.length > 1 ? `${round(median(xs), d)} (${round(Math.min(...xs), d)} to ${round(Math.max(...xs), d)})` : `${round(xs[0], d)}`);
for (const g of ['cross', 'd1', 'd1real', 'parse', 'sha']) {
  const rows = [...cases.values()].filter((c) => c.group === g);
  if (!rows.length) continue;
  console.log(`\n${g}\n\n| case | us per operation |\n| --- | --- |`);
  for (const c of rows) console.log(`| ${c.name} | ${cell(c.us, c.us[0] < 10 ? 3 : 1)} |`);
}
const parts = runs.map((r) => r.find((o) => o.parts)?.parts).filter(Boolean);
if (parts.length) {
  const pick = (f) => parts.map(f);
  console.log('\nparts of one crossing (us per call)\n');
  console.log('| part | rows 20 | rows 200 |\n| --- | --- | --- |');
  for (const k of ['js_encode_tree', 'js_encode_packed', 'js_encode_packed_made', 'zig_decode_tree', 'zig_decode_packed']) {
    console.log(`| ${k} | ${cell(pick((p) => p.rows[0][k].us), 2)} | ${cell(pick((p) => p.rows[1][k].us), 2)} |`);
  }
  console.log(`| bytes (tree, packed) | ${parts[0].rows[0].tree_bytes}, ${parts[0].rows[0].packed_bytes} | ${parts[0].rows[1].tree_bytes}, ${parts[0].rows[1].packed_bytes} |`);
  console.log('\n| part | 1 op | 4 ops | 16 ops |\n| --- | --- | --- | --- |');
  for (const k of ['js_decode', 'zig_decode', 'zig_decode_encode', 'js_run', 'js_encode_result']) {
    console.log(`| ${k} | ${[0, 1, 2].map((i) => cell(pick((p) => p.program[i][k].us), 3)).join(' | ')} |`);
  }
}
