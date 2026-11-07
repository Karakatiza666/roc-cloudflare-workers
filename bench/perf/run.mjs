#!/usr/bin/env node
// The per-PR performance bench of the platform (bench/perf/README.md).
// It builds the pinned registry app on this checkout (host and platform), serves it in Miniflare with the pinned seed,
// sends the pinned scenarios, and appends one row for each (commit, scenario, metric) to results/rows.jsonl.
//   node bench/perf/run.mjs [--rounds 3] [--requests N] [--warm 600] [--scenarios small,closure] [--out <rows.jsonl>] [--no-append]
//                           [--wasm <app.wasm>] [--shim <dir>] [--build-only] [--label <text>] [--commit <text>] [--platform-root <dir>]
// --platform-root: build the host and the app on the platform of this checkout (default: this one; CI builds the base of a PR with it).
// --commit: the commit text of the rows (default: git short hash, +dirty when the tree has changes outside bench/perf/results and research/).
// --wasm: use this app.wasm, no build. --shim: use this shim dir (default js/). --out: the rows file (default results/rows.jsonl).
// Env: ZIG (Zig 0.17, for the build), ROC (default: bench/get-roc.sh), MINIFLARE (the miniflare package dir, as js/test.mjs),
//      PERF_SOURCE=proc forces the fallback metric (CPU time from /proc) when perf is not wanted. PERF_SOURCE=vg: Ir of valgrind (callgrind) instead of perf (opt in).
// A round is one fresh Miniflare for each scenario: a first (cold) request, 600 warm-up requests (--warm), then --requests measured requests.
// The row value is the median of the rounds. Rows of the metric source `perf` (instructions of workerd, idle rate subtracted)
// are comparable across runs on one machine type. Rows of the source `proc` (CPU ms) only inside one job.
import { spawn, spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { appendFileSync, cpSync, rmSync, existsSync, mkdirSync, readFileSync, readdirSync, readlinkSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { wasmInfo } from '../../research/regprof/wasminfo.mjs';
import { toCsv } from './rows.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const corpus = join(here, 'corpus');
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith('--')) continue;
  const k = argv[i].slice(2);
  opt[k] = argv[i + 1] === undefined || argv[i + 1].startsWith('--') ? true : argv[++i];
}
const rounds = Number(opt.rounds ?? 3);
// Measured requests for each scenario: a long window averages the V8 tier-up and GC threads (small: 400 requests spread 4.3 %, 2000 requests 1.5 %).
const REQUESTS = { small: 2000, search: 1000, releases: 1000, compat: 1000, closure: 500, 'mixed-ro': 800 };
const requestsOf = (sc) => Number(opt.requests ?? REQUESTS[sc] ?? 500);
// V8 tiers up the wasm in the first requests: with 30 warm-up requests `small` costs 7.4 M instructions, with 150 4.4 M, with 500 4.15 M (spread 0.15 %).
const WARM = Number(opt.warm ?? 600);
const NOW = '2026-11-07T12:00:00Z';
const scenarios = String(opt.scenarios ?? 'small,search,releases,closure,compat,mixed-ro').split(',');
const outFile = resolve(opt.out ?? join(here, 'results/rows.jsonl'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sh = (cmd, args, o = {}) => spawnSync(cmd, args, { encoding: 'utf8', cwd: root, ...o });
const median = (a) => { const b = [...a].sort((x, y) => x - y); const n = b.length; return n % 2 ? b[(n - 1) / 2] : (b[n / 2 - 1] + b[n / 2]) / 2; };

// ---- Build: host (zig), then the pinned app on the platform of this checkout ----
function build(proot) {
  const cache = join(proot, '.cache/perf');
  mkdirSync(cache, { recursive: true });
  const roc = process.env.ROC ?? sh('bench/get-roc.sh').stdout.trim();
  if (!roc) throw new Error('no roc: set ROC or run with gh installed (bench/get-roc.sh)');
  const env = { ...process.env, ROC_CACHE_DIR: join(root, '.cache/roc'), XDG_CACHE_HOME: join(root, '.cache'), ZIG_GLOBAL_CACHE_DIR: join(root, '.cache/zig') };
  if (!process.env.ZIG) throw new Error('set ZIG to the Zig 0.17 binary');
  console.error(`build: zig build (the host of ${proot})`);
  let r = sh(process.env.ZIG, ['build'], { env, cwd: proot, stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.status !== 0) throw new Error('zig build failed');
  // A copy of the pinned app inside proot, so that its pf line names the platform of proot (a PR run builds the base the same way).
  const appDir = join(cache, 'app');
  rmSync(appDir, { recursive: true, force: true });
  cpSync(join(corpus, 'app'), appDir, { recursive: true });
  const mainRoc = join(appDir, 'main.roc');
  writeFileSync(mainRoc, readFileSync(mainRoc, 'utf8').replace(/pf: platform "[^"]*"/, 'pf: platform "../../../platform/main.roc"'));
  const wasm = join(cache, 'app.wasm');
  console.error('build: roc build of the pinned app (3 to 5 minutes)');
  r = sh(roc, ['build', '--target=wasm32', '--opt=speed', '--no-cache', `--output=${wasm}`, mainRoc], { env, cwd: proot, stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.status !== 0 && r.status !== 2) throw new Error(`roc build failed (exit ${r.status})`); // exit 2: warnings only
  return wasm;
}

// ---- Counters: perf stat instructions of the workerd process (source perf), valgrind Ir of workerd (source vg), or the CPU time of /proc (source proc) ----
// Auto choice: perf when it works, else proc. valgrind (vg) is only used with PERF_SOURCE=vg: its Ir has a 26 % jump between runs (V8 wasm tier-up state, README "Without perf").
const perfOk = process.env.PERF_SOURCE !== 'proc' && process.env.PERF_SOURCE !== 'vg' && (() => {
  const r = sh('perf', ['stat', '-x', ',', '-e', 'instructions', 'true']);
  return r.status === 0 && /^\d+,/m.test(r.stderr);
})();
const CG_CONTROL = process.env.CALLGRIND_CONTROL ?? 'callgrind_control';
const vgOk = process.env.PERF_SOURCE === 'vg' && sh(process.env.VALGRIND ?? 'valgrind', ['--version']).status === 0 && sh(CG_CONTROL, ['--help']).status === 0;
const SOURCE = perfOk ? 'perf' : vgOk ? 'vg' : 'proc';
const cgDir = join(root, '.cache/perf/cg');

// valgrind: workerd runs under callgrind (exact Ir count, no hardware counter). Miniflare starts workerd from MINIFLARE_WORKERD_PATH.
// `--separate-threads=yes`: one file for each thread. The Ir of the busiest thread (the event loop, with V8, wasm and the host) is the metric: it has 98 %
// of the Ir, and the helper threads (GC, compile) have a timing noise of 5 to 15 %. A dump (`callgrind_control -d`) writes the Ir since the last dump into new part files.
function setupVg() {
  const req = createRequire(join(process.env.MINIFLARE ?? root, 'package.json'));
  const real = process.env.WORKERD ?? (() => {
    try { return req('workerd').default; } catch { /* next */ }
    return join(process.env.MINIFLARE ?? '', '../@cloudflare/workerd-linux-64/bin/workerd');
  })();
  if (!existsSync(real)) throw new Error('no workerd binary: set WORKERD');
  rmSync(cgDir, { recursive: true, force: true });
  mkdirSync(cgDir, { recursive: true });
  const wrapper = join(cgDir, 'workerd-vg.sh');
  writeFileSync(wrapper, `#!/bin/sh\nexec "${process.env.VALGRIND ?? 'valgrind'}" --tool=callgrind --callgrind-out-file="${cgDir}/cg.%p" --separate-threads=yes --trace-children=no -q "${real}" "$@"\n`, { mode: 0o755 });
  process.env.MINIFLARE_WORKERD_PATH = wrapper;
}
// Dump the callgrind counters of the process and give the Ir of the part that this dump closed.
function vgDump(pid) {
  const parts = () => new Set(readdirSync(cgDir).filter((f) => f.startsWith(`cg.${pid}`)));
  const before = parts();
  const r = sh(CG_CONTROL, ['-d', String(pid)]);
  if (r.status !== 0) throw new Error(`callgrind_control -d failed: ${r.stderr}`);
  const fresh = [...parts()].filter((f) => !before.has(f));
  if (!fresh.length) throw new Error('callgrind: no new part file after a dump');
  const irs = fresh.map((f) => Number(readFileSync(join(cgDir, f), 'utf8').match(/^(?:totals|summary): (\d+)/m)?.[1] ?? 0));
  return Math.max(...irs);
}

function workerdOf(nodePid) {
  for (const p of readdirSync('/proc').filter((x) => /^\d+$/.test(x))) {
    try {
      const exe = readlinkSync(`/proc/${p}/exe`);
      if (!(SOURCE === 'vg' ? /callgrind-/.test(exe) : exe.endsWith('/workerd'))) continue;
      if (Number(readFileSync(`/proc/${p}/stat`, 'utf8').split(') ')[1].split(' ')[1]) === nodePid) return Number(p);
    } catch { /* gone */ }
  }
  return null;
}
// CPU time of all threads of the process in ms: the run time of the scheduler (ns, /proc/<pid>/task/<tid>/schedstat) when it is there, else the ticks (10 ms) of stat.
function cpuMs(pid) {
  return readdirSync(`/proc/${pid}/task`).reduce((a, t) => {
    try {
      const ns = Number(readFileSync(`/proc/${pid}/task/${t}/schedstat`, 'utf8').split(' ')[0]);
      if (Number.isFinite(ns) && ns > 0) return a + ns / 1e6;
    } catch { /* no schedstat */ }
    try { const f = readFileSync(`/proc/${pid}/task/${t}/stat`, 'utf8').split(') ')[1].split(' '); return a + (Number(f[11]) + Number(f[12])) * 10; } catch { return a; }
  }, 0);
}
// Run fn while counting. Gives { ins, cpu, ms, extra }. ins is null when the source is proc. For vg, ins is the Ir.
async function count(pid, fn) {
  let p; let err = '';
  if (SOURCE === 'perf') {
    p = spawn('perf', ['stat', '-x', ',', '-e', 'instructions', '-p', String(pid)], { stdio: ['ignore', 'ignore', 'pipe'] });
    p.stderr.on('data', (d) => { err += d; });
    await sleep(150);
  }
  if (SOURCE === 'vg') vgDump(pid); // close the part before: its Ir is not counted
  const t0 = performance.now();
  const c0 = cpuMs(pid);
  const extra = await fn();
  const c1 = cpuMs(pid);
  const ms = performance.now() - t0;
  let ins = null;
  if (SOURCE === 'vg') ins = vgDump(pid);
  if (p) {
    p.kill('SIGINT');
    await new Promise((r) => p.on('close', r));
    for (const l of err.trim().split('\n')) { const f = l.split(','); if (f[2]?.startsWith('instructions')) ins = Number(f[0]); }
    if (!Number.isFinite(ins)) throw new Error(`perf stat gave no instructions: ${err.trim()}`);
  }
  return { ins, cpu: c1 - c0, ms, extra };
}

// ---- The requests ----
const lines = (sc) => readFileSync(join(corpus, 'scenarios', `${sc}.jsonl`), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
async function send(app, line, acc) {
  const headers = { 'user-agent': 'tln-bench/0', accept: 'application/json', ...(line.headers ?? {}) };
  let body;
  if (line.json !== undefined) { body = JSON.stringify(line.json); headers['content-type'] ??= 'application/json'; }
  else if (line.body !== undefined) body = line.body;
  const r = await app.fetch(line.path, { method: line.method, headers, body });
  await r.arrayBuffer();
  if (r.status !== line.expected_status) acc.bad++;
  const st = r.headers.get('x-roc-stats');
  if (st) {
    const s = JSON.parse(st);
    acc.allocs += s.allocs; acc.bytes += s.bytes; acc.cross += s.cross ?? 0; acc.xbytes += s.xbytes ?? 0; acc.mem = Math.max(acc.mem, s.mem); acc.n++;
  }
}
const newAcc = () => ({ allocs: 0, bytes: 0, cross: 0, xbytes: 0, mem: 0, n: 0, bad: 0 });
async function series(app, ls, n, acc, from = 0) { for (let i = from; i < from + n; i++) await send(app, ls[i % ls.length], acc); }

// One round of one scenario on a fresh Miniflare.
async function oneRun(sc, wasm, shim) {
  const requests = requestsOf(sc);
  const { startApp } = await import(pathToFileURL(join(shim, 'test.mjs')).href);
  const d1 = ['0001_init.sql', '0002_triggers.sql', 'seed.sql'].map((f) => join(corpus, 'db', f));
  const app = await startApp({
    dir: corpus, shim, wasm, config: join(corpus, 'wrangler.toml'), now: Date.parse(NOW),
    bindings: { CONTRIBUTOR_KEY: 'bench' }, d1: { DB: d1 }, options: { stats: true }, miniflare: process.env.MINIFLARE,
  });
  try {
    const pid = workerdOf(process.pid);
    if (!pid) throw new Error('no workerd child process');
    const ls = lines(sc);
    await sleep(500);
    const idle = await count(pid, () => sleep(1000));
    const rate = (k) => (idle[k] ?? 0) / idle.ms; // per ms
    const accCold = newAcc();
    const cold = await count(pid, () => send(app, ls[0], accCold));
    const acc0 = newAcc();
    await series(app, ls, WARM, acc0);
    const acc = newAcc();
    // Blocks of whole scenario cycles (about 100 requests): each block has the same request mix, so the minimum of the blocks is a fair
    // low-noise value (source proc: noise from other processes only adds CPU time).
    const B = ls.length * Math.ceil(100 / ls.length);
    const blocks = [];
    const run = await count(pid, async () => {
      for (let done = 0; done < requests; done += B) {
        const n = Math.min(B, requests - done);
        const c = cpuMs(pid); const t = performance.now();
        await series(app, ls, n, acc, done);
        if (n === B) blocks.push({ n, cpu: cpuMs(pid) - c, ms: performance.now() - t });
      }
    });
    if (acc.bad) console.error(`warning: ${sc}: ${acc.bad} responses with an unexpected status`);
    const m = {};
    const per = (k) => (run[k] - rate(k) * run.ms) / requests;
    if (SOURCE !== 'proc') {
      const sfx = SOURCE === 'vg' ? 'ir' : 'ins'; // perf: ins_*, valgrind: ir_*
      m[`${sfx}_per_req`] = per('ins');
      if (sc === 'small') { // the cold request is clean only for the first request of `small` (GET /v1/toolchains)
        m[`cold_first_${sfx}`] = cold.ins - rate('ins') * cold.ms;
        m[`cold_extra_${sfx}`] = m[`cold_first_${sfx}`] - m[`${sfx}_per_req`];
      }
    } else {
      m.cpu_ms_per_req = per('cpu');
      if (blocks.length) m.cpu_min_ms_per_req = Math.min(...blocks.map((b) => (b.cpu - rate('cpu') * b.ms) / b.n));
      if (sc === 'small') m.cold_first_cpu_ms = cold.cpu - rate('cpu') * cold.ms;
    }
    m.mem_peak_bytes = Math.max(acc.mem, accCold.mem);
    m.allocs_per_req = acc.allocs / Math.max(1, acc.n);
    m.alloc_bytes_per_req = acc.bytes / Math.max(1, acc.n);
    m.cross_per_req = acc.cross / Math.max(1, acc.n);
    m.xbytes_per_req = acc.xbytes / Math.max(1, acc.n);
    if (SOURCE === 'perf') m.cpu_ms_per_req = per('cpu'); // informational
    return m;
  } finally {
    await app.close().catch(() => {});
  }
}

// ---- Static metrics of app.wasm ----
function staticMetrics(wasm) {
  const info = wasmInfo(readFileSync(wasm));
  return { app_wasm_bytes: statSync(wasm).size, largest_fn_bytes: Math.max(...info.bodies.map((b) => b.size)), wasm_functions: info.bodies.length };
}

// ---- Main ----
const wasm = resolve(opt.wasm ?? build(resolve(opt['platform-root'] ?? root)));
if (opt['build-only']) { console.log(wasm); process.exit(0); }
if (SOURCE === 'vg') setupVg();
const shim = resolve(opt.shim ?? join(root, 'js'));
const git = (a) => sh('git', a).stdout.trimEnd();
// Not dirty: the rows (bench/perf/results), research/, and the dirs that CI adds next to the sources: `data` (the checkout of bench-data), `base` (the base of a PR).
const dirtyList = git(['status', '--porcelain', '--', '.', ':!bench/perf/results', ':!research', ':!data', ':!base']);
const dirty = dirtyList !== '';
if (dirty) console.error(`dirty tree:\n${dirtyList}`); // name the files, so a +dirty row is never a mystery
const commit = typeof opt.commit === 'string' ? opt.commit : `${git(['rev-parse', '--short=8', 'HEAD'])}${dirty ? '+dirty' : ''}`;
const date = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const nightly = readFileSync(join(root, 'compat/last-stack-first-nightly'), 'utf8').trim();
console.error(`source: ${SOURCE}${SOURCE === 'perf' ? '' : SOURCE === 'vg' ? ' (perf is not usable: Ir of valgrind)' : ' (no perf: the CPU time of /proc, comparable only inside one job)'}; commit ${commit}; ${rounds} rounds x ${scenarios.length} scenarios`);

const UNIT = { ins_per_req: 'instructions', cold_first_ins: 'instructions', cold_extra_ins: 'instructions', ir_per_req: 'instructions', cold_first_ir: 'instructions', cold_extra_ir: 'instructions', cpu_ms_per_req: 'ms', cpu_min_ms_per_req: 'ms', cold_first_cpu_ms: 'ms', mem_peak_bytes: 'bytes', allocs_per_req: 'count', alloc_bytes_per_req: 'bytes', cross_per_req: 'count', xbytes_per_req: 'bytes', app_wasm_bytes: 'bytes', largest_fn_bytes: 'bytes', wasm_functions: 'count' };
const rows = [];
const base = { commit, date, nightly, where: 'local', label: typeof opt.label === 'string' ? opt.label : '' };
const add = (scenario, metric, vals, n, source) => rows.push({ ...base, scenario, metric, value: median(vals), unit: UNIT[metric], requests: n, rounds: vals.length, min: Math.min(...vals), max: Math.max(...vals), source });
for (const [k, v] of Object.entries(staticMetrics(wasm))) add('static', k, [v], 0, 'static');
const all = Object.fromEntries(scenarios.map((s) => [s, {}]));
for (let r = 0; r < rounds; r++) {
  for (const sc of scenarios) {
    const m = await oneRun(sc, wasm, shim);
    for (const [k, v] of Object.entries(m)) (all[sc][k] ??= []).push(v);
    console.error(`round ${r + 1} ${sc}: ${Object.entries(m).map(([k, v]) => `${k}=${v >= 1e5 ? (v / 1e6).toFixed(3) + 'M' : v.toFixed(2)}`).join(' ')}`);
  }
}
const srcOf = (k) => (UNIT[k] === 'instructions' ? SOURCE : UNIT[k] === 'ms' ? 'proc' : 'stats');
for (const sc of scenarios) for (const [k, vals] of Object.entries(all[sc])) add(sc, k, vals, k.startsWith('cold') ? 1 : requestsOf(sc), srcOf(k));

console.table(rows.map((r) => ({ scenario: r.scenario, metric: r.metric, value: Number(r.value.toPrecision(6)), min: Number(r.min.toPrecision(6)), max: Number(r.max.toPrecision(6)), source: r.source })));
if (!opt['no-append']) {
  mkdirSync(dirname(outFile), { recursive: true });
  appendFileSync(outFile, rows.map((r) => `${JSON.stringify(r)}\n`).join(''));
  const all2 = readFileSync(outFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  writeFileSync(outFile.replace(/\.jsonl$/, '.csv'), toCsv(all2));
  console.error(`appended ${rows.length} rows to ${outFile}`);
} else {
  writeFileSync(outFile.replace(/\.jsonl$/, '.last.json'), JSON.stringify(rows));
}
process.exit(0);
