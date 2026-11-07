#!/usr/bin/env node
// Mermaid charts (xychart-beta) from the rows file, written to a markdown file.
//   node bench/perf/chart.mjs [--rows bench/perf/results/rows.jsonl] [--out bench/perf/results/CHART.md] [--last 30]
// One point for each run (commit). A run with the same commit again replaces the earlier point. Only rows of the metric source `perf` give the
// instruction charts: a row of another source never mixes with them.
import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readRows, runsOf } from './rows.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i += 2) opt[argv[i].replace(/^--/, '')] = argv[i + 1];
const rowsFile = resolve(opt.rows ?? join(here, 'results/rows.jsonl'));
const outFile = resolve(opt.out ?? join(here, 'results/CHART.md'));
const keep = Number(opt.last ?? 30);
const allRuns = runsOf(readRows(rowsFile));
const lastPer = (where) => { const m = new Map(); for (const r of allRuns.filter((x) => x.where === where)) m.set(r.commit, r); return [...m.values()].slice(-keep); };
const runs = lastPer('local');
const edgeRuns = lastPer('edge');
const lines = [];
const localRuns = runs;
const num = (v) => Number(v.toPrecision(5));
function chart(title, ylabel, series, scale, runs = localRuns) {
  const have = series.filter((s) => runs.some((r) => r.get(s.scenario, s.metric) !== undefined));
  if (!have.length) return;
  const ys = have.flatMap((s) => runs.map((r) => r.get(s.scenario, s.metric)).filter((v) => v !== undefined)).map((v) => v / scale);
  const lo = Math.min(...ys); const hi = Math.max(...ys);
  const pad = (hi - lo) * 0.1 || hi * 0.05 || 1;
  lines.push(`### ${title}`, '', ...have.map((s, i) => `- Line ${i + 1}: ${s.name}`), '', '```mermaid', 'xychart-beta', `    title "${title}"`,
    `    x-axis [${runs.map((r) => `"${r.commit.slice(0, 7)}"`).join(', ')}]`, `    y-axis "${ylabel}" ${num(Math.max(0, lo - pad))} --> ${num(hi + pad)}`);
  for (const s of have) {
    let prev = null;
    const vals = runs.map((r) => { const v = r.get(s.scenario, s.metric); if (v !== undefined) prev = v / scale; return prev ?? 0; });
    lines.push(`    line [${vals.map(num).join(', ')}]`);
  }
  lines.push('```', '');
}
lines.push('# Platform performance bench', '', `Runs: ${runs.length} (${runs[0]?.commit ?? '-'} to ${runs.at(-1)?.commit ?? '-'}). Source rows: \`${rowsFile.replace(/^.*\/(?=bench\/)/, '')}\`. Charts of the local rows use one point for each commit. The edge chart has the edge rows of the post-merge job (CPU time of the real runtime). The instruction charts are workerd instructions for each request with the idle rate subtracted.`, '');
chart('Instructions per request, small (M)', 'M instructions', [{ scenario: 'small', metric: 'ins_per_req', name: 'small, steady' }], 1e6);
chart('Cold extra of the first request, small (M)', 'M instructions', [{ scenario: 'small', metric: 'cold_extra_ins', name: 'first request minus steady' }], 1e6);
chart('Instructions per request, other scenarios (M)', 'M instructions', ['search', 'releases', 'closure', 'compat', 'mixed-ro'].map((s) => ({ scenario: s, metric: 'ins_per_req', name: s })), 1e6);
chart('Allocations per request', 'allocs', ['small', 'closure', 'mixed-ro'].map((s) => ({ scenario: s, metric: 'allocs_per_req', name: s })), 1);
chart('Size of app.wasm and its largest function (KB)', 'KB', [{ scenario: 'static', metric: 'app_wasm_bytes', name: 'app.wasm' }, { scenario: 'static', metric: 'largest_fn_bytes', name: 'largest function' }], 1024);
chart('Edge CPU time of the bench Worker (ms, Workers analytics, after merge)', 'ms', [{ scenario: 'edge-series', metric: 'cpu_p50_us', name: 'p50' }, { scenario: 'edge-series', metric: 'cpu_p90_us', name: 'p90' }, { scenario: 'edge-series', metric: 'cpu_p99_us', name: 'p99' }], 1000, edgeRuns);
chart('Peak wasm memory (MB)', 'MB', [{ scenario: 'small', metric: 'mem_peak_bytes', name: 'small' }, { scenario: 'closure', metric: 'mem_peak_bytes', name: 'closure' }, { scenario: 'mixed-ro', metric: 'mem_peak_bytes', name: 'mixed-ro' }], 1048576);
const last = runs.at(-1);
if (last) {
  const sc = [...new Set(last.rows.map((r) => r.scenario))].filter((s) => s !== 'static');
  const f = (v, d = 3, k = 1e6) => (v === undefined ? '' : (v / k).toFixed(d));
  lines.push(`### Latest run (${last.commit}, ${last.date}, nightly ${last.nightly})`, '', '| Scenario | M ins per request | Cold extra, M ins | Allocs per request | Peak memory, MB |', '| --- | --- | --- | --- | --- |',
    ...sc.map((s) => `| ${s} | ${f(last.get(s, 'ins_per_req'))} | ${f(last.get(s, 'cold_extra_ins'), 2)} | ${f(last.get(s, 'allocs_per_req'), 1, 1)} | ${f(last.get(s, 'mem_peak_bytes'), 1, 1048576)} |`), '',
    `app.wasm ${f(last.get('static', 'app_wasm_bytes'), 0, 1024)} KB, largest function ${f(last.get('static', 'largest_fn_bytes'), 0, 1024)} KB.`, '');
}
writeFileSync(outFile, lines.join('\n'));
console.error(`wrote ${outFile}`);
