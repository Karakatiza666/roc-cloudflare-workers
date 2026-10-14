// Q13: the bench on the Cloudflare edge (the Workers from bench/deploy.sh).
// EDGE=<account>.workers.dev node bench/edge.mjs [n=1000] > .cache/results/edge.jsonl
// Client side: latency, req/s, errors, bad bodies. Server side: cpuTime and wallTime of each
// request from `wrangler tail` (whole ms), joined to the request by its id.
import { spawn } from 'node:child_process';
import { check } from './core.js';

const EDGE = process.env.EDGE;
const N = Number(process.argv[2] || 1000);
const DEPTHS = (process.env.DEPTHS || '0,130,530').split(',').map(Number);
const VARIANTS = (process.env.VARIANTS || 'j,a,b').split(',');
const base = (v) => `https://talon-bench-${v}.${EDGE}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const q = (xs, p) => xs[Math.min(xs.length - 1, Math.floor(p * xs.length))];
const mean = (xs) => +(xs.reduce((a, b) => a + b, 0) / xs.length).toFixed(2);
let nextId = Date.now() % 1e9;

// One `wrangler tail` per Worker. Events: url -> {cpuTime, wallTime, outcome}.
const events = new Map();
function tail(v) {
  const p = spawn('wrangler', ['tail', `talon-bench-${v}`, '--format', 'json'], { stdio: ['ignore', 'pipe', 'ignore'] });
  let buf = '';
  p.stdout.on('data', (d) => {
    buf += d;
    for (;;) { // the stream is pretty-printed JSON objects, one after the other
      const end = buf.indexOf('\n}\n');
      if (end < 0) break;
      const o = JSON.parse(buf.slice(0, end + 2));
      buf = buf.slice(end + 3);
      const url = o.event?.request?.url;
      if (url) events.set(url, { cpu: o.cpuTime, wall: o.wallTime, outcome: o.outcome });
    }
  });
  return p;
}

async function load(v, conc, n, depth, path = '/h') {
  const lat = [], urls = [];
  let bad = 0, errors = 0, i = 0, colo = '';
  const t0 = performance.now();
  async function worker() {
    while (i < n) {
      i++;
      const id = String(nextId++);
      const url = `${base(v)}${path}?id=${id}&trap=0&depth=${depth}`;
      urls.push(url);
      const s = performance.now();
      try {
        const r = await fetch(url);
        const body = await r.text();
        lat.push(performance.now() - s);
        colo ||= (r.headers.get('cf-ray') || '').split('-')[1];
        if (r.status !== 200) errors++;
        else if (!check(id, body, depth)) bad++;
      } catch {
        errors++;
      }
    }
  }
  await Promise.all(Array.from({ length: conc }, worker));
  const secs = (performance.now() - t0) / 1000;
  lat.sort((a, b) => a - b);
  return { variant: v, depth, conc, n, colo, p50: +q(lat, 0.5).toFixed(1), p99: +q(lat, 0.99).toFixed(1), rps: Math.round(n / secs), errors, bad, urls };
}

// Join with the tail events: server cpu and wall time (ms), outcomes other than "ok".
function server(r) {
  const ev = r.urls.map((u) => events.get(u)).filter(Boolean);
  const cpu = ev.map((e) => e.cpu).sort((a, b) => a - b), wall = ev.map((e) => e.wall).sort((a, b) => a - b);
  const notOk = ev.filter((e) => e.outcome !== 'ok').map((e) => e.outcome);
  const { urls, ...rest } = r;
  return { ...rest, traced: ev.length, cpuMean: mean(cpu), cpuP50: q(cpu, 0.5), cpuP99: q(cpu, 0.99), wallP50: q(wall, 0.5), wallP99: q(wall, 0.99), notOk };
}

// Instantiate cost: server cpuTime of /inst?n=K minus /inst?n=0, per instance (us).
async function inst(pad, k, reps = 5) {
  const one = async (n) => {
    const url = `${base('a')}/inst?n=${n}&pad=${pad}&r=${nextId++}`;
    await (await fetch(url)).text();
    return url;
  };
  const u0 = [], uk = [];
  for (let i = 0; i < reps; i++) { u0.push(await one(0)); uk.push(await one(k)); }
  return { u0, uk, pad, k };
}
function instResult({ u0, uk, pad, k }) {
  const c = (us) => us.map((u) => events.get(u)?.cpu).filter((x) => x !== undefined).sort((a, b) => a - b);
  const c0 = c(u0), ck = c(uk);
  return { inst: true, pad, k, cpu0: c0, cpuK: ck, usPerInstance: Math.round(((q(ck, 0.5) - q(c0, 0.5)) * 1000) / k) };
}

const tails = ['a', 'b', 'j'].map(tail);
await sleep(30000); // tail needs some seconds to connect, and it drops events (best effort)
const rows = [];
for (const v of VARIANTS) {
  await load(v, 16, 200, 50); // warmup
  for (const depth of v === 'j' ? [0] : DEPTHS) {
    for (const c of [1, 16, 64]) rows.push(await load(v, c, c === 1 ? Math.min(N, 200) : N, depth));
  }
}
const insts = [await inst(0, 200), await inst(1, 50)];
// Memory of the shared instance (B): /stats of the isolates that answer.
const stats = [];
for (let i = 0; i < 30; i++) stats.push(await (await fetch(`${base('b')}/stats?r=${nextId++}`)).json());
await sleep(20000); // let the last tail events arrive
tails.forEach((p) => p.kill());
for (const r of rows) console.log(JSON.stringify(server(r)));
for (const x of insts) console.log(JSON.stringify(instResult(x)));
const served = stats.map((s) => s.served);
console.log(JSON.stringify({ stats: true, samples: stats.length, isolatesSeen: new Set(stats.map((s) => `${s.served}`)).size, maxMem: Math.max(...stats.map((s) => s.mem || 0)), maxSavedPeak: Math.max(...stats.map((s) => s.saved_peak || 0)), served }));
