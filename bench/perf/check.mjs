#!/usr/bin/env node
// The budget check of the bench (bench/perf/README.md "Budget"). Exit 1 when a rule fails.
//   node bench/perf/check.mjs --head <rows.jsonl> [--base <rows.jsonl>] [--budget bench/perf/budget.json] [--summary <file.md>]
// The head run is the last run of the head file. The base run is the last run of the base file (from the same machine and job, or
// the last row of main). Two kinds of rule (budget.json):
//   relative: the head value may not be more than max_pct above the base value. Needs --base.
//   absolute: the value of the head run, converted with calibration.ins_per_ms, may not be above max_ms. A fixed share of the 10 ms CPU limit.
// With the metric source `proc` (no perf), the instruction rules use the CPU ms metric, with the threshold times proc_factor, and the absolute rules are skipped.
import { readFileSync, appendFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readRows, runsOf } from './rows.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i += 2) opt[argv[i].replace(/^--/, '')] = argv[i + 1];
if (!opt.head) { console.error('usage: check.mjs --head <rows.jsonl> [--base <rows.jsonl>] [--budget <budget.json>] [--summary <file.md>]'); process.exit(2); }
const budget = JSON.parse(readFileSync(resolve(opt.budget ?? join(here, 'budget.json')), 'utf8'));
// The runs of the last commit in the file, merged: the median of each (scenario, metric) over the runs (a CI job runs the head and the base in turn).
const median = (a) => { const b = [...a].sort((x, y) => x - y); const n = b.length; return n % 2 ? b[(n - 1) / 2] : (b[n / 2 - 1] + b[n / 2]) / 2; };
function last(f) {
  const runs = runsOf(readRows(resolve(f))).filter((r) => r.where === 'local');
  if (!runs.length) return undefined;
  const mine = runs.filter((r) => r.commit === runs[runs.length - 1].commit);
  const key = new Map();
  for (const r of mine.flatMap((x) => x.rows)) { const k = `${r.scenario}|${r.metric}`; if (!key.has(k)) key.set(k, []); key.get(k).push(r.value); }
  return { commit: mine[0].commit, runs: mine.length, rows: [...key].map(([k]) => ({ scenario: k.split('|')[0], metric: k.split('|')[1] })), get: (sc, m) => (key.has(`${sc}|${m}`) ? median(key.get(`${sc}|${m}`)) : undefined) };
}
const head = last(opt.head);
const base = opt.base ? last(opt.base) : null;
if (!head) { console.error('check: no rows in the head file'); process.exit(2); }
const proc = head.get('small', 'ins_per_req') === undefined;
const PROC = { ins_per_req: 'cpu_ms_per_req', cold_first_ins: 'cold_first_cpu_ms', cold_extra_ins: null };
const metricOf = (m) => (proc && m in PROC ? PROC[m] : m);
const scenariosOf = (run, sc) => (sc === '*' ? [...new Set(run.rows.map((r) => r.scenario))].filter((s) => s !== 'static') : [sc]);

const out = [];
let fail = false;
const add = (rule, scenario, metric, head_, base_, limit, status) => out.push({ rule, scenario, metric, head: head_, base: base_, limit, status });
for (const r of budget.relative) {
  if (!base) continue;
  const m = metricOf(r.metric);
  if (!m) continue;
  const pct = r.max_pct * (proc && r.metric in PROC ? budget.proc_factor : 1);
  for (const sc of scenariosOf(head, r.scenario)) {
    if (r.scenario === '*' && budget.relative.some((x) => x.scenario === sc && x.metric === r.metric)) continue; // the rule of that scenario is more specific
    const h = head.get(sc, m); const b = base.get(sc, m);
    if (h === undefined || b === undefined) continue;
    const d = ((h - b) / b) * 100;
    const bad = d > pct;
    if (bad) fail = true;
    add('relative', sc, m, h, b, `+${pct.toFixed(1)} %`, `${d >= 0 ? '+' : ''}${d.toFixed(2)} % ${bad ? 'FAIL' : 'ok'}`);
  }
}
for (const r of budget.absolute) {
  if (proc && r.metric in PROC) { add('absolute', r.scenario, r.metric, null, null, `${r.max_ms} ms`, 'skipped (no perf)'); continue; }
  const h = head.get(r.scenario, r.metric);
  if (h === undefined) continue;
  // ms of the CPU limit: instructions / ins_per_ms, times the share of workerd CPU that the edge also pays (Miniflare and local D1 do not run on the edge).
  const ms = (h / budget.calibration.ins_per_ms) * (r.edge_share ?? 1);
  const bad = ms > r.max_ms;
  if (bad) fail = true;
  const note = r.target_ms !== undefined && ms > r.target_ms ? `, above the target ${r.target_ms} ms` : '';
  add('absolute', r.scenario, r.metric, h, null, `${r.max_ms} ms`, `${ms.toFixed(2)} ms${bad ? ' FAIL' : ' ok'}${note}`);
}

const fmt = (v) => (v === null || v === undefined ? '' : v >= 1e5 ? `${(v / 1e6).toFixed(3)} M` : Number(v.toPrecision(5)).toString());
const md = [
  `Perf bench: head ${head.commit}${base ? `, base ${base.commit}` : ', no base'} (${head.runs} head runs${base ? `, ${base.runs} base runs` : ''}), metric source ${proc ? 'proc (CPU ms)' : 'perf (instructions)'}: **${fail ? 'FAIL' : 'pass'}**`.replace(/\*\*/g, ''),
  '',
  '| Rule | Scenario | Metric | Head | Base | Limit | Result |',
  '| --- | --- | --- | --- | --- | --- | --- |',
  ...out.map((o) => `| ${o.rule} | ${o.scenario} | ${o.metric} | ${fmt(o.head)} | ${fmt(o.base)} | ${o.limit} | ${o.status} |`),
].join('\n');
console.log(md);
if (opt.summary) writeFileSync(resolve(opt.summary), `${md}\n`);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${md}\n`);
process.exit(fail ? 1 : 0);
