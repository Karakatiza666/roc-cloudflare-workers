#!/usr/bin/env node
// The edge part of the bench: CPU time on the real Workers runtime (post-merge job only, needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID).
//   node bench/perf/edge.mjs deploy  [--wasm app.wasm]   deploy the corpus app to talon-registry-bench, print the version id
//   node bench/perf/edge.mjs run     --version <id> [--commit <text>] [--out rows.jsonl]   send the series, wait, read the CPU quantiles, append rows
//   node bench/perf/edge.mjs query   --version <id> [--since <iso>] [--script <name>]      only read the analytics (read only, prints JSON)
// The series: 100 x `small` and 300 x `mixed-ro` (400 requests, sequential, read only). The free plan allows 100,000 requests a day.
// The rows have where=edge, scenario `edge-series`, source `analytics`, metrics cpu_p50_us, cpu_p90_us, cpu_p99_us, edge_requests (CPU time in microseconds).
// The quantiles cover all requests of the version, so the p99 includes the first (cold) requests of each isolate. One version only: no traffic split.
import { spawnSync } from 'node:child_process';
import { appendFileSync, cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { toCsv, readRows } from './rows.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const [cmd, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, '')] = rest[i + 1];
const SCRIPT = opt.script ?? 'talon-registry-bench';
const BASE = process.env.EDGE_BASE ?? 'https://talon-registry-bench.bellup.workers.dev';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const need = (n) => { if (!process.env[n]) { console.error(`edge: set ${n}`); process.exit(2); } return process.env[n]; };

function deploy() {
  const dir = join(root, '.cache/perf/edge');
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  cpSync(join(root, 'js'), join(dir, '.roc-cfw'), { recursive: true });
  cpSync(resolve(opt.wasm ?? join(root, '.cache/perf/app.wasm')), join(dir, 'app.wasm'));
  cpSync(join(here, 'corpus/wrangler.edge.toml'), join(dir, 'wrangler.toml'));
  writeFileSync(join(dir, 'worker.js'), "import app from './app.wasm';\nimport { makeHandler } from './.roc-cfw/index.js';\n\nexport default makeHandler(app);\n");
  need('CLOUDFLARE_API_TOKEN'); need('CLOUDFLARE_ACCOUNT_ID');
  const r = spawnSync('wrangler', ['deploy'], { cwd: dir, encoding: 'utf8' });
  process.stderr.write(r.stdout + r.stderr);
  if (r.status !== 0) process.exit(1);
  const m = /Current Version ID:\s*([0-9a-f-]{36})/i.exec(r.stdout + r.stderr);
  if (!m) { console.error('edge: no version id in the wrangler output'); process.exit(1); }
  console.log(m[1]);
}

// CPU quantiles (microseconds) of one version. The dataset is workersInvocationsAdaptive; `quantiles` has cpuTimeP50, P90, P99.
export async function analytics(version, sinceIso, untilIso = new Date().toISOString()) {
  const account = need('CLOUDFLARE_ACCOUNT_ID');
  const query = `query($account: String!, $script: String!, $since: Time!, $until: Time!) {
    viewer { accounts(filter: { accountTag: $account }) {
      workersInvocationsAdaptive(limit: 100, filter: { scriptName: $script, datetime_geq: $since, datetime_leq: $until }) {
        dimensions { scriptVersion status }
        sum { requests errors }
        quantiles { cpuTimeP50 cpuTimeP90 cpuTimeP99 }
      } } } }`;
  const r = await fetch('https://api.cloudflare.com/client/v4/graphql', {
    method: 'POST', headers: { authorization: `Bearer ${need('CLOUDFLARE_API_TOKEN')}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query, variables: { account, script: SCRIPT, since: sinceIso, until: untilIso } }),
  });
  const j = await r.json();
  if (j.errors?.length) throw new Error(`graphql: ${j.errors[0].message}`);
  const groups = (j.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive ?? []);
  return version ? groups.filter((g) => g.dimensions.scriptVersion === version) : groups;
}
// Groups are by status. The quantiles of the groups cannot be merged exactly: take the group with most requests (the status ok), and report the total.
function pick(groups) {
  if (!groups.length) return null;
  const total = groups.reduce((a, g) => a + g.sum.requests, 0);
  const g = groups.reduce((a, b) => (b.sum.requests > a.sum.requests ? b : a));
  return { requests: total, p50: g.quantiles.cpuTimeP50, p90: g.quantiles.cpuTimeP90, p99: g.quantiles.cpuTimeP99 };
}

const lines = (sc) => readFileSync(join(here, 'corpus/scenarios', `${sc}.jsonl`), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
async function series() {
  const plan = [['small', 100], ['mixed-ro', 300]];
  let sent = 0; let bad = 0;
  for (const [sc, n] of plan) {
    const ls = lines(sc);
    for (let i = 0; i < n; i++) {
      const l = ls[i % ls.length];
      const headers = { 'user-agent': 'tln-bench/0', accept: 'application/json' };
      let body;
      if (l.json !== undefined) { body = JSON.stringify(l.json); headers['content-type'] = 'application/json'; }
      const r = await fetch(BASE + l.path, { method: l.method, headers, body });
      await r.arrayBuffer();
      sent++;
      if (r.status !== l.expected_status) bad++;
      await sleep(60); // gentle: the Worker keeps its isolate, and the rate stays low
    }
  }
  return { sent, bad };
}

async function run() {
  const version = opt.version;
  if (!version) { console.error('edge: --version is needed'); process.exit(2); }
  const since = new Date(Date.now() - 60_000).toISOString();
  const { sent, bad } = await series();
  console.error(`edge: sent ${sent} requests, ${bad} with an unexpected status`);
  let got = null;
  for (let i = 0; i < 20; i++) { // analytics lag: poll up to 20 minutes
    await sleep(60_000);
    got = pick(await analytics(version, since));
    console.error(`edge: poll ${i + 1}: ${got ? `${got.requests} requests` : 'no data'}`);
    if (got && got.requests >= sent * 0.95) break;
  }
  if (!got || got.requests < sent * 0.5) { console.error('edge: analytics gave too few requests'); process.exit(1); }
  const git = (a) => spawnSync('git', a, { cwd: root, encoding: 'utf8' }).stdout.trim();
  const base = { commit: opt.commit ?? git(['rev-parse', '--short=8', 'HEAD']), date: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), nightly: readFileSync(join(root, 'compat/last-stack-first-nightly'), 'utf8').trim(), label: `version ${version}`, where: 'edge', scenario: 'edge-series', unit: 'us', requests: sent, rounds: 1, source: 'analytics' };
  const rows = [['cpu_p50_us', got.p50], ['cpu_p90_us', got.p90], ['cpu_p99_us', got.p99], ['edge_requests', got.requests]].map(([metric, value]) => ({ ...base, metric, value, min: value, max: value, unit: metric === 'edge_requests' ? 'count' : 'us' }));
  const out = resolve(opt.out ?? join(here, 'results/rows.jsonl'));
  appendFileSync(out, rows.map((r) => `${JSON.stringify(r)}\n`).join(''));
  writeFileSync(out.replace(/\.jsonl$/, '.csv'), toCsv(readRows(out)));
  console.error(`edge: p50 ${got.p50} us, p90 ${got.p90} us, p99 ${got.p99} us; rows appended to ${out}`);
}

if (cmd === 'deploy') deploy();
else if (cmd === 'run') await run();
else if (cmd === 'query') console.log(JSON.stringify(await analytics(opt.version, opt.since ?? new Date(Date.now() - 86400_000).toISOString()), null, 1));
else { console.error('usage: edge.mjs deploy | run --version <id> | query [--version <id>]'); process.exit(2); }
