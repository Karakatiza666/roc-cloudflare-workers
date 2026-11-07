// Counts of a trace by kind of call (sizes from the trace itself; small = up to 2,048 B, v6/v7 classes).
// node tstats.mjs <trace>...   Per trace: calls by kind, tasks, waits, calls per task, bytes per task.
import { readFileSync } from 'node:fs';
const CL = [16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048];
const cls = (n) => (n > 2048 ? -1 : CL.findIndex((c) => c >= Math.max(n, 1)));
for (const name of process.argv.slice(2)) {
  const tr = new Uint32Array(readFileSync(new URL(`../out/trace_${name}.bin`, import.meta.url)).buffer.slice(0));
  const len = new Map();
  const c = {};
  const inc = (k, n = 1) => (c[k] = (c[k] ?? 0) + n);
  const owners = new Set();
  const classesOf = new Map();
  for (let i = 0; i < tr.length; i += 4) {
    const op = tr[i] & 0xff, owner = tr[i + 1], id = tr[i + 2], n = tr[i + 3];
    if (owner) owners.add(owner);
    if (op === 1) { len.set(id, n); inc(n <= 2048 ? 'allocSmall' : 'allocLarge'); inc('bytesAlloc', n); if (n <= 2048) { const s = classesOf.get(owner) ?? new Set(); s.add(cls(n)); classesOf.set(owner, s); } }
    else if (op === 2) { inc(len.get(id) <= 2048 ? 'freeSmall' : 'freeLarge'); len.delete(id); }
    else if (op === 3) {
      const o = len.get(id) ?? 0;
      if (n <= 2048 && o <= 2048) inc(cls(n) === cls(o) || n <= o ? 'reallocSmallSame' : 'reallocSmallMove');
      else if (o <= 2048) inc('reallocSmallToLarge');
      else if (n <= o) inc('reallocLargeShrink');
      else inc('reallocLargeGrow');
      len.set(id, n);
      if (n <= 2048) { const s = classesOf.get(owner) ?? new Set(); s.add(cls(n)); classesOf.set(owner, s); }
    } else if (op === 4) inc('taskEnd'); else if (op === 5) inc('wait'); else if (op === 6) inc('adopt');
  }
  const tasks = c.taskEnd ?? owners.size;
  const calls = (c.allocSmall ?? 0) + (c.allocLarge ?? 0) + (c.freeSmall ?? 0) + (c.freeLarge ?? 0) + Object.entries(c).filter(([k]) => k.startsWith('realloc')).reduce((a, [, v]) => a + v, 0);
  const avgClasses = [...classesOf.values()].reduce((a, s) => a + s.size, 0) / classesOf.size;
  console.log(name, JSON.stringify({ tasks, calls, callsPerTask: Math.round(calls / tasks), waitsPerTask: +((c.wait ?? 0) / tasks).toFixed(1), smallClassesPerTask: +avgClasses.toFixed(1), ...c }));
}
