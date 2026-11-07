// Allocator cost in CPU cycles and instructions (perf stat, user space only), less noisy than
// wall time on a shared machine: cycles do not count the time when the process waits for a core.
// A pair of processes, with 3 warm-up runs and then 0 or N more runs: the difference / N is one trace.
// node pstat.mjs <trace> <N> <pairs> <sum modes, e.g. 0,2> <versions>...
// Prints per version and mode: median M cycles and M instructions per trace, and the p25 to p75 of cycles.
import { spawnSync } from 'node:child_process';
const [name, n0, pairs0, modes0, ...vers] = process.argv.slice(2);
const [N, pairs] = [Number(n0), Number(pairs0)];
const modes = modes0.split(',').map(Number);
const script = new URL('rone.mjs', import.meta.url).pathname;
const stat = (v, s, runs) => {
  const r = spawnSync('perf', ['stat', '-x', ',', '-e', 'cycles:u,instructions:u', 'node', ...(process.env.NODE_FLAGS ? process.env.NODE_FLAGS.split(' ') : []), script, name, v, String(s), String(runs)], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stderr;
};
const parse = (txt) => { const m = {}; for (const l of txt.trim().split('\n')) { const f = l.split(','); if (f[2]?.startsWith('cycles')) m.c = +f[0]; if (f[2]?.startsWith('instructions')) m.i = +f[0]; } return m; };
const q = (a, p) => { const b = [...a].sort((x, y) => x - y); return b[Math.min(b.length - 1, Math.floor(p * b.length))]; };
const res = new Map();
for (let p = 0; p < pairs; p++) for (const v of vers) for (const s of modes) {
  const a = parse(stat(v, s, 0));
  const b = parse(stat(v, s, N));
  const k = `${v}|${s}`;
  if (!res.has(k)) res.set(k, { c: [], i: [] });
  res.get(k).c.push((b.c - a.c) / N / 1e6);
  res.get(k).i.push((b.i - a.i) / N / 1e6);
}
const rows = [...res].map(([k, r]) => { const [v, s] = k.split('|'); return { v, sum: +s, Mcycles: +q(r.c, 0.5).toFixed(1), p25_p75: `${q(r.c, 0.25).toFixed(1)}..${q(r.c, 0.75).toFixed(1)}`, Minstr: +q(r.i, 0.5).toFixed(1), iSpread: `${q(r.i, 0.25).toFixed(1)}..${q(r.i, 0.75).toFixed(1)}` }; });
console.log(`trace ${name}: per trace, ${N} runs, ${pairs} pairs`);
console.table(rows);
