// Tables from out/<v>-n<N>-kb<KB>.jsonl (heavy.mjs). Prints markdown; --csv <file> writes mem in 10 s bins per run.
//   node report.mjs [--glob <prefix filter>] [--csv out/series.csv]
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const D = join(dirname(fileURLToPath(import.meta.url)), 'out');
const opt = {};
for (let i = 2; i < process.argv.length; i += 2) opt[process.argv[i].slice(2)] = process.argv[i + 1];
const MB = 2 ** 20;
const f2 = (x) => (x / MB).toFixed(1);
const runs = [];
for (const f of readdirSync(D)) {
  const m = f.match(/^(base|fa_dl|fa_zig|alloc_c1360|alloc_spans)-n(\d+)-kb(\d+)(.*)\.jsonl$/);
  if (!m) continue;
  if (opt.glob && !f.startsWith(opt.glob)) continue;
  const rows = readFileSync(join(D, f), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  if (!rows.length) continue;
  runs.push({ v: m[1], n: +m[2], kb: +m[3], tag: m[4], rows });
}
const order = { base: 0, alloc_c1360: 1, alloc_spans: 2, fa_dl: 3, fa_zig: 4 };
runs.sort((a, b) => a.kb - b.kb || a.n - b.n || a.tag.localeCompare(b.tag) || order[a.v] - order[b.v]);

const summary = (r) => {
  const ok = r.rows.filter((x) => x.status === 200);
  const bad = r.rows.filter((x) => x.status !== 200);
  const mx = (a) => a.reduce((m, x) => (x > m ? x : m), 0);
  const tEnd = mx(r.rows.map((x) => x.t1));
  const memAt = (t) => mx(r.rows.filter((x) => x.t1 <= t && x.mem).map((x) => x.mem));
  const maxMem = memAt(Infinity);
  const livePeak = mx(ok.map((x) => x.livePeak ?? 0));
  const held = ok.map((x) => +(x.body.match(/held (\d+)/)?.[1] ?? 0));
  const heldMax = mx(held);
  // Mem at the end of each third (phase) and at 90 % of each phase: growth in the last 10 % of a phase.
  const third = tEnd / 3;
  const phaseEnd = [1, 2, 3].map((k) => memAt(third * k));
  const p90 = [1, 2, 3].map((k) => memAt(third * (k - 0.5)));
  const firstBad = bad.length ? bad.reduce((m, x) => Math.min(m, x.t1), Infinity) : null;
  const kinds = {};
  for (const b of bad) {
    const k = `${b.status} ${String(b.body).slice(0, 60)}`;
    kinds[k] = (kinds[k] ?? 0) + 1;
  }
  return { ok: ok.length, bad: bad.length, maxMem, livePeak, heldMax, phaseEnd, p90, firstBad, kinds, tEnd };
};

const lines = [];
lines.push('| KB per task | N | Variant | Tasks ok | Failed | First fail s | Max mem MB | Global live peak MB | N x held MB | mem / live peak | mem end of s, b, m MB | Growth in 2nd half of m MB |');
lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|');
const out = [];
for (const r of runs) {
  const s = summary(r);
  out.push({ ...r, s });
  lines.push(`| ${r.kb}${r.tag} | ${r.n} | ${r.v} | ${s.ok} | ${s.bad} | ${s.firstBad === null ? '-' : (s.firstBad / 1000).toFixed(0)} | ${f2(s.maxMem)} | ${f2(s.livePeak)} | ${f2(r.n * s.heldMax)} | ${s.livePeak ? (s.maxMem / s.livePeak).toFixed(2) : '-'} | ${s.phaseEnd.map(f2).join(', ')} | ${f2(s.phaseEnd[2] - s.p90[2])} |`);
}
console.log(lines.join('\n'));
console.log('\nFailures:');
for (const r of out) if (r.s.bad) console.log(`${r.v} n${r.n} kb${r.kb}${r.tag}: ${JSON.stringify(r.s.kinds)}`);

if (opt.csv) {
  const rowsCsv = ['run,t_s,mem_mb'];
  for (const r of out) {
    const bins = new Map();
    let m = 0;
    for (const x of [...r.rows].sort((a, b) => a.t1 - b.t1)) {
      if (x.mem > m) m = x.mem;
      bins.set(Math.floor(x.t1 / 10000), m);
    }
    for (const [b, mm] of bins) rowsCsv.push(`${r.v}-n${r.n}-kb${r.kb}${r.tag},${(b + 1) * 10},${f2(mm)}`);
  }
  writeFileSync(opt.csv, rowsCsv.join('\n') + '\n');
}
