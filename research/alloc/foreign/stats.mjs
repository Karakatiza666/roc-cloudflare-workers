// Tables from cpuseries.mjs --out files: per series and metric, the median (p25 to p75) of each variant, and the
// change of the median against the first variant (base). The A/A noise: the change of a second copy of the base.
//   node stats.mjs <out.json>... [--base base] [--rounds a-b] (only rounds a to b, from 1, of each file)
// Metrics: every perf event of the run per request, CPU ms, peak wasm memory, peak live KB, RSS.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const files = args.filter((a) => !a.startsWith('--') && !args[args.indexOf(a) - 1]?.startsWith('--'));
const opt = {};
for (let i = 0; i < args.length; i++) if (args[i].startsWith('--')) opt[args[i].slice(2)] = args[++i];
const q = (a, p) => {
  const b = [...a].sort((x, y) => x - y);
  const i = p * (b.length - 1);
  const lo = Math.floor(i);
  return b[lo] + (b[Math.min(lo + 1, b.length - 1)] - b[lo]) * (i - lo);
};
// Join the rounds of the same series and variant over all files.
const all = {};
for (const f of files) {
  const j = JSON.parse(readFileSync(f, 'utf8'));
  const [ra, rb] = (opt.rounds ?? '1-999').split('-').map(Number);
  for (const [sk, vs] of Object.entries(j.all)) for (const [vn, rs] of Object.entries(vs)) ((all[sk] ??= {})[vn] ??= []).push(...rs.slice(ra - 1, rb));
}
const metricsOf = (r) => ({ ...Object.fromEntries(Object.entries(r.ev ?? {}).map(([k, v]) => [k, v])), cpuMs: r.cpuMsPerReq, memMB: r.memMB, liveKB: r.livePeakKB });
for (const [sk, vs] of Object.entries(all)) {
  const names = Object.keys(vs);
  const base = opt.base ?? names[0];
  const ms = Object.keys(metricsOf(vs[base][0]));
  console.log(`\n## ${sk} (rounds: ${names.map((n) => `${n} ${vs[n].length}`).join(', ')})\n`);
  console.log(`| Metric per request | ${names.join(' | ')} |`);
  console.log(`|---|${names.map(() => '---').join('|')}|`);
  for (const m of ms) {
    const val = (n) => vs[n].map((r) => metricsOf(r)[m]).filter((x) => Number.isFinite(x));
    const bm = q(val(base), 0.5);
    const big = Math.abs(bm) >= 1e5;
    const fmt = (x) => (big ? (x / 1e6).toFixed(3) : Math.abs(x) >= 100 ? x.toFixed(0) : x.toFixed(3));
    const cells = names.map((n) => {
      const v = val(n);
      const md = q(v, 0.5);
      const iqr = ((q(v, 0.75) - q(v, 0.25)) / Math.abs(md)) * 100;
      const d = n === base ? '' : `, ${md >= bm ? '+' : ''}${(((md - bm) / Math.abs(bm)) * 100).toFixed(2)} %`;
      return `${fmt(md)}${d} (IQR ${iqr.toFixed(1)} %)`;
    });
    console.log(`| ${m}${big ? ', M' : ''} | ${cells.join(' | ')} |`);
  }
}
