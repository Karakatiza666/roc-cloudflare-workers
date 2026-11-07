// The total CPU of the registry Worker on a fixed series of requests, for allocator variants (research/alloc v9).
//   node cpuseries.mjs --series mixed:2000:1,mixed:2000:8 --rounds 5 [--warm 100] [--out <file.json>] <name>=<W2 dir> ...
// <W2 dir>: app.wasm (the registry built on a platform copy with the host of the variant) and .roc-cfw/.
// Series item: <scenario>:<requests>:<concurrency>; the requests of the scenario file in order, again from the start when the file ends.
// Per round, per series, per variant (interleaved: round 1 of all variants, then round 2, ...):
//   a fresh server (serve.sh: the seed of state/, fixed TALON_NOW, stats header on), a warm-up of --warm requests of the
//   scenario, 1 s idle (the idle rate of instructions and cycles), then the series under `perf stat -p <workerd>`
//   (all threads, user and kernel), the CPU time of workerd from /proc (all threads), and the peak RSS.
// The result per request: instructions, cycles, CPU ms, with the idle rate times the series time subtracted.
// Each response: status, and the sha256 of the body ({{uniq}} is a counter, so the bodies are the same in each run).
// The stats header (x-roc-stats) gives the peak wasm memory and the peak of live bytes in a request.
// Prints a table (median, p25 to p75 per variant) and the body check (all variants against the first). Exit 1 on a body difference.
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, readlinkSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = {};
const vars = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) opt[argv[i].slice(2)] = argv[++i];
  else { const [n, d] = argv[i].split('='); vars.push({ name: n, dir: resolve(d) }); }
}
const rounds = Number(opt.rounds ?? 5);
const warm = Number(opt.warm ?? 100);
const series = (opt.series ?? 'mixed:2000:1').split(',').map((s) => { const [sc, n, c] = s.split(':'); return { sc, n: Number(n), c: Number(c ?? 1), key: s }; });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJsonl = (f) => readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const scen = (sc) => readJsonl(join(here, 'scenarios', `${sc}.jsonl`));

function cpuMs(pid) {
  return readdirSync(`/proc/${pid}/task`).reduce((a, t) => {
    try { const f = readFileSync(`/proc/${pid}/task/${t}/stat`, 'utf8').split(') ')[1].split(' '); return a + (Number(f[11]) + Number(f[12])) * 10; } catch { return a; }
  }, 0);
}
const hwmKB = (pid) => Number(/VmHWM:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]);
function workerdOf(nodePid) {
  for (const p of readdirSync('/proc').filter((x) => /^\d+$/.test(x))) {
    try {
      if (!readlinkSync(`/proc/${p}/exe`).endsWith('/workerd')) continue;
      if (Number(readFileSync(`/proc/${p}/stat`, 'utf8').split(') ')[1].split(' ')[1]) === nodePid) return Number(p);
    } catch { /* gone */ }
  }
  return null;
}
async function perfStat(pid, fn) {
  const p = spawn('perf', ['stat', '-x', ',', '-e', 'instructions,cycles,page-faults', '-p', String(pid)], { stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  p.stderr.on('data', (d) => { err += d; });
  await sleep(150);
  const t0 = performance.now();
  const c0 = cpuMs(pid);
  const extra = await fn();
  const c1 = cpuMs(pid);
  const ms = performance.now() - t0;
  p.kill('SIGINT');
  await new Promise((r) => p.on('close', r));
  const m = {};
  for (const l of err.trim().split('\n')) { const f = l.split(','); if (f[2]) m[f[2].replace(/:.*$/, '')] = Number(f[0]); }
  return { ins: m.instructions, cyc: m.cycles, pf: m['page-faults'], cpu: c1 - c0, ms, extra };
}

let counter = 0n;
const fill = (s) => (typeof s === 'string' && s.includes('{{uniq}}') ? s.replaceAll('{{uniq}}', () => (counter++).toString(16).padStart(32, '0')) : s);
async function send(base, line, acc) {
  const headers = { 'user-agent': 'tln-bench/0', accept: 'application/json', ...Object.fromEntries(Object.entries(line.headers ?? {}).map(([k, v]) => [k.toLowerCase(), fill(v)])) };
  let body;
  if (line.json !== undefined) { body = fill(JSON.stringify(line.json)); headers['content-type'] ??= 'application/json'; }
  else if (line.body !== undefined) body = fill(line.body);
  const r = await fetch(base + line.path, { method: line.method, headers, body, redirect: 'manual' });
  const buf = Buffer.from(await r.arrayBuffer());
  const st = r.headers.get('x-roc-stats');
  if (st && acc) { const s = JSON.parse(st); acc.mem = Math.max(acc.mem, s.mem); acc.live = Math.max(acc.live, s.livePeak); }
  return `${r.status} ${createHash('sha256').update(buf).digest('hex').slice(0, 16)}`;
}
async function runSeries(base, lines, n, c, acc) {
  const out = new Array(n);
  let next = 0;
  const worker = async () => { for (;;) { const i = next++; if (i >= n) return; out[i] = await send(base, lines[i % lines.length], acc); } };
  await Promise.all(Array.from({ length: c }, worker));
  return out;
}

async function one(v, s) {
  const state = join(here, 'state');
  rmSync(join(state, 'worker.url'), { force: true });
  const env = { ...process.env, W2_DIR: v.dir, TALON_NOW: '2026-11-07T12:00:00Z', MINIFLARE_WORKERD_V8_FLAGS: '', CFW_TEST_OPTIONS: '{"stats":true}' };
  delete env.CFW_TEST_TRACE;
  const srv = spawn(join(here, 'serve.sh'), [], { env, stdio: ['ignore', 'ignore', 'inherit'] });
  try {
    for (let i = 0; !existsSync(join(state, 'worker.url')); i++) { if (i > 600 || srv.exitCode !== null) throw new Error(`${v.name}: no server`); await sleep(200); }
    const base = readFileSync(join(state, 'worker.url'), 'utf8').trim();
    const wd = workerdOf(srv.pid);
    if (!wd) throw new Error('no workerd');
    const lines = scen(s.sc);
    counter = 0n;
    await runSeries(base, lines, warm, 1, null);
    const idle = await perfStat(wd, () => sleep(1000));
    counter = 1n << 40n;
    const acc = { mem: 0, live: 0 };
    const run = await perfStat(wd, () => runSeries(base, lines, s.n, s.c, acc));
    const k = run.ms / idle.ms;
    const res = {
      insPerReq: (run.ins - idle.ins * k) / s.n, cycPerReq: (run.cyc - idle.cyc * k) / s.n, cpuMsPerReq: (run.cpu - idle.cpu * k) / s.n,
      pfPerReq: run.pf / s.n, wallMs: run.ms, idleInsPerS: idle.ins / (idle.ms / 1000), memMB: acc.mem / 2 ** 20, livePeakKB: acc.live / 1024, rssMB: hwmKB(wd) / 1024,
      bodies: run.extra,
    };
    await fetch(`${base}/__regserve/stop`, { method: 'POST' }).catch(() => {});
    return res;
  } finally {
    await Promise.race([new Promise((r) => srv.on('close', r)), sleep(15000)]);
    if (srv.exitCode === null) srv.kill('SIGKILL');
  }
}

const q = (a, p) => { const b = [...a].sort((x, y) => x - y); return b[Math.min(b.length - 1, Math.floor(p * b.length))]; };
const all = {};
for (let r = 0; r < rounds; r++) {
  for (const s of series) {
    for (const v of (r % 2 ? [...vars].reverse() : vars)) {
      const res = await one(v, s);
      ((all[s.key] ??= {})[v.name] ??= []).push(res);
      console.error(`round ${r + 1} ${s.key} ${v.name}: ${(res.insPerReq / 1e6).toFixed(2)} M ins, ${(res.cycPerReq / 1e6).toFixed(2)} M cyc, ${res.cpuMsPerReq.toFixed(2)} ms cpu per request; mem ${res.memMB.toFixed(2)} MB, live peak ${res.livePeakKB.toFixed(0)} KB`);
    }
  }
}
let same = true;
const rows = [];
for (const s of series) {
  const ref = all[s.key][vars[0].name][0].bodies;
  for (const v of vars) {
    const rs = all[s.key][v.name];
    const diff = rs.reduce((a, x) => a + x.bodies.filter((b, i) => b !== ref[i]).length, 0);
    if (diff) same = false;
    const f = (key, d, sc = 1) => `${(q(rs.map((x) => x[key]), 0.5) / sc).toFixed(d)} (${(q(rs.map((x) => x[key]), 0.25) / sc).toFixed(d)}..${(q(rs.map((x) => x[key]), 0.75) / sc).toFixed(d)})`;
    rows.push({ series: s.key, v: v.name, Mins: f('insPerReq', 3, 1e6), Mcyc: f('cycPerReq', 3, 1e6), cpuMs: f('cpuMsPerReq', 2), pf: f('pfPerReq', 1), memMB: Math.max(...rs.map((x) => x.memMB)).toFixed(2), liveKB: Math.max(...rs.map((x) => x.livePeakKB)).toFixed(0), rssMB: f('rssMB', 0), bodyDiff: diff });
  }
}
console.table(rows);
if (opt.out) writeFileSync(opt.out, JSON.stringify({ series, rounds, warm, all: Object.fromEntries(Object.entries(all).map(([k, o]) => [k, Object.fromEntries(Object.entries(o).map(([n, rs]) => [n, rs.map(({ bodies, ...x }) => x)]))])), rows }, null, 1));
console.log(same ? 'bodies: same in all variants and rounds' : 'bodies: DIFFER');
process.exit(same ? 0 : 1);
