// Load generator and driver. Each rep starts a fresh workerd for the variant.
// WORKERD=<path> node bench/bench.mjs [reps=3] [n=5000]          latency, throughput, copy bytes by depth (DEPTHS, VARIANTS)
// WORKERD=<path> node bench/bench.mjs leak [n=10000] [rate=0.01] the trap leak test
// WORKERD=<path> RESUME_CHECK=off|afterAlarm|always ITEMS=<n> CONCS=64 VARIANTS=b DEPTHS=50 node bench/bench.mjs 5 3000
//   the cost of the checks in workerd (12f). RESUME_CHECK and ITEMS: see worker.js. CONCS: the concurrencies (default 1,16,64).
//   Each row also has cpuUsPerReq: the CPU time of the workerd process (utime + stime) per request.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { check } from './core.js';

const here = dirname(fileURLToPath(import.meta.url));
const WORKERD = process.env.WORKERD;
const BASE = 'http://127.0.0.1:8131';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let nextId = 100000;

const cpuMs = (pid) => {
  const f = readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' '); // fields from 3: utime is 14, stime 15
  return ((Number(f[11]) + Number(f[12])) * 1000) / 100; // clock ticks of 10 ms
};
const rssKB = (pid) => Number(/VmRSS:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]);

async function start(variant, pad = '0') {
  const p = spawn(WORKERD, ['serve', join(here, `config-${variant}.capnp`)], { env: { ...process.env, PAD: pad }, stdio: ['ignore', 'ignore', 'inherit'] });
  for (let i = 0; i < 100; i++) {
    await sleep(100);
    try {
      if ((await fetch(BASE + '/stats')).ok) return p;
    } catch {}
  }
  throw new Error('workerd did not start');
}
async function stop(p) {
  p.kill('SIGTERM');
  await new Promise((r) => p.once('exit', r));
}

// n requests with `conc` in flight. A request with trap=1 must answer 500.
async function load(conc, n, trapRate = 0, depth = 50) {
  const lat = [];
  let bad = 0, errors = 0, traps = 0, i = 0;
  const t0 = performance.now();
  async function worker() {
    while (i < n) {
      i++;
      const id = String(nextId++);
      const trap = trapRate > 0 && Math.random() < trapRate;
      const s = performance.now();
      try {
        const r = await fetch(`${BASE}/h?id=${id}&trap=${trap ? 1 : 0}&depth=${depth}${process.env.ITEMS ? '&items=' + process.env.ITEMS : ''}`);
        const body = await r.text();
        lat.push(performance.now() - s);
        if (trap) {
          if (r.status === 500) traps++;
          else bad++;
        } else if (r.status !== 200) errors++;
        else if (!check(id, body, depth)) bad++;
      } catch {
        errors++;
      }
    }
  }
  await Promise.all(Array.from({ length: conc }, worker));
  const secs = (performance.now() - t0) / 1000;
  lat.sort((a, b) => a - b);
  const q = (p) => lat[Math.min(lat.length - 1, Math.floor(p * lat.length))];
  return { conc, n, p50: +q(0.5).toFixed(2), p99: +q(0.99).toFixed(2), rps: Math.round(n / secs), errors, bad, traps };
}

const stats = async () => (await fetch(BASE + '/stats')).json();

const mode = process.argv[2];
if (mode === 'leak') {
  const n = Number(process.argv[3] || 10000), rate = Number(process.argv[4] || 0.01);
  for (const v of ['b']) {
    for (const r of [rate, 0]) {
      const p = await start(v);
      await load(16, 500);
      const s0 = await stats(), rss0 = rssKB(p.pid);
      const res = await load(16, n, r);
      await sleep(500);
      const s1 = await stats(), rss1 = rssKB(p.pid);
      console.log(JSON.stringify({ variant: v, trapRate: r, ...res, rssBeforeKB: rss0, rssAfterKB: rss1, before: s0, after: s1 }));
      await stop(p);
    }
  }
} else {
  // Rows: variant x depth x concurrency. The copy counters are zeroed before each row.
  const reps = Number(mode || 3), n = Number(process.argv[3] || 5000);
  const depths = (process.env.DEPTHS || '0,30,130,530').split(',').map(Number);
  for (let rep = 1; rep <= reps; rep++) {
    for (const v of (process.env.VARIANTS || 'j,b').split(',')) {
      const p = await start(v);
      const rssStart = rssKB(p.pid);
      await load(16, 1000); // warmup
      const rssWarm = rssKB(p.pid);
      for (const depth of v === 'j' ? [0] : depths) {
        for (const c of (process.env.CONCS || '1,16,64').split(',').map(Number)) {
          await fetch(BASE + '/reset');
          const cpu0 = cpuMs(p.pid);
          const r = await load(c, n, 0, depth);
          const cpuUsPerReq = Math.round(((cpuMs(p.pid) - cpu0) * 1000) / n);
          const s = await stats();
          console.log(JSON.stringify({ rep, variant: v, depth, ...r, cpuUsPerReq, rssKB: rssKB(p.pid), memBytes: s.mem, savedMax: s.saved_max, savedPeak: s.saved_peak, waits: s.waits }));
        }
      }
      console.log(JSON.stringify({ rep, variant: v, rssStartKB: rssStart, rssWarmKB: rssWarm, rssEndKB: rssKB(p.pid), stats: await stats() }));
      await stop(p);
    }
  }
}
