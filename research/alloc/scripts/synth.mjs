// Synthetic traces (format as trace.mjs) for sizes the bench app does not make.
// node synth.mjs <kind> [tasks=64] [turns=4000] -> out/trace_synth_<kind>.bin
// Kinds (block sizes): med = log-uniform 2 to 16 KB; mix = 80 % 16 to 512 B, 20 % log-uniform
// 1 to 64 KB; grow = small blocks plus one buffer per task that grows 1.5x to 1 MB.
// Tasks take turns: a turn is 40 calls, then a wait (sum). A task lives 20 to 60 turns.
import { writeFileSync } from 'node:fs';
const [kind, tasks = 64, turns = 4000] = [process.argv[2], ...process.argv.slice(3).map(Number)];
let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0), seed / 2 ** 32);
const logU = (a, b) => Math.round(Math.exp(Math.log(a) + rnd() * (Math.log(b) - Math.log(a))));
const size = () => {
  if (kind === 'med') return logU(2048, 16384);
  if (kind === 'mix') return rnd() < 0.8 ? 16 + Math.floor(rnd() * 496) : logU(1024, 65536);
  return 16 + Math.floor(rnd() * 240);
};
let buf = new Uint32Array(1 << 22), n = 0;
const put = (op, owner, id, len) => {
  if (n + 4 > buf.length) { const b = new Uint32Array(buf.length * 2); b.set(buf); buf = b; }
  buf[n++] = op; buf[n++] = owner; buf[n++] = id; buf[n++] = len;
};
const freeIds = [];
let nextId = 0, owners = 0, liveB = 0, livePeak = 0;
const add = (d) => { liveB += d; if (liveB > livePeak) livePeak = liveB; };
const newTask = () => ({ owner: ++owners, live: [], lens: new Map(), left: 20 + Math.floor(rnd() * 40), grow: -1 });
const slots = Array.from({ length: tasks }, newTask);
for (let turn = 0; turn < turns; turn++) {
  const t = slots[turn % tasks];
  for (let k = 0; k < 40; k++) {
    const r = rnd();
    if (kind === 'grow' && k === 0) {
      // One buffer per task grows 1.5x per turn up to 1 MB, then it is freed.
      if (t.grow < 0) { const id = freeIds.length ? freeIds.pop() : nextId++; t.grow = id; t.lens.set(id, 2400); add(2400); put(1 | (4 << 8), t.owner, id, 2400); }
      else if (t.lens.get(t.grow) < 1 << 20) { const l = Math.round(t.lens.get(t.grow) * 1.5); add(l - t.lens.get(t.grow)); t.lens.set(t.grow, l); put(3 | (4 << 8), t.owner, t.grow, l); }
      else { put(2, t.owner, t.grow, 0); freeIds.push(t.grow); add(-t.lens.get(t.grow)); t.lens.delete(t.grow); t.grow = -1; }
    } else if (r < 0.45 || t.live.length === 0) {
      const id = freeIds.length ? freeIds.pop() : nextId++;
      const len = size();
      t.live.push(id); t.lens.set(id, len); add(len);
      put(1 | (4 << 8), t.owner, id, len);
    } else if (r < 0.9) {
      const i = Math.floor(rnd() * t.live.length);
      const id = t.live[i]; t.live[i] = t.live[t.live.length - 1]; t.live.pop();
      add(-t.lens.get(id)); t.lens.delete(id); freeIds.push(id);
      put(2, t.owner, id, 0);
    } else {
      const id = t.live[Math.floor(rnd() * t.live.length)];
      const len = Math.min(1 << 20, Math.round(t.lens.get(id) * 1.5)); add(len - t.lens.get(id)); t.lens.set(id, len);
      put(3 | (4 << 8), t.owner, id, len);
    }
  }
  put(5, t.owner, 0, 0);
  if (--t.left === 0) {
    for (const [id, l] of t.lens) { freeIds.push(id); add(-l); }
    put(4, t.owner, 0, 0);
    slots[turn % tasks] = newTask();
  }
}
const out = new URL(`../out/trace_synth_${kind}.bin`, import.meta.url);
writeFileSync(out, buf.subarray(0, n));
console.log(out.pathname, { records: n / 4, ids: nextId, livePeakMB: +(livePeak / 2 ** 20).toFixed(1) });
