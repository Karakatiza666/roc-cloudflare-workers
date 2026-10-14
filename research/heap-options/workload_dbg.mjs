// Mixed workload over the allocator prototypes.
// node workload.mjs <variant> [profile=mixed|phase|bench] [seed=1] [stepPages=1] [tasks=20000]
import { readFileSync } from 'node:fs';
const [v, profile = 'mixed', seedArg = '1', stepArg = '1', tasksArg = '20000'] = process.argv.slice(2);
const { instance } = await WebAssembly.instantiate(readFileSync(new URL(`out/${v}.wasm`, import.meta.url)));
const x = instance.exports;
const memv = () => new Uint32Array(x.memory.buffer);
x.h_set_step(+stepArg);

let s = +seedArg >>> 0 || 1;
const rnd = () => { s |= 0; s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const logU = (lo, hi) => Math.floor(Math.exp(Math.log(lo) + rnd() * (Math.log(hi) - Math.log(lo))));
function size(phase) {
  const r = rnd();
  if (profile === 'phase' && phase === 0) return r < 0.5 ? logU(16, 4096) : logU(4096, 1 << 20);
  if (profile === 'phase' && phase === 1) return logU(16, 2048);
  if (profile === 'small') return r < 0.7 ? logU(16, 256) : r < 0.95 ? logU(256, 4096) : logU(4096, 65536);
  if (r < 0.70) return logU(16, 256);
  if (r < 0.90) return logU(256, 4096);
  if (r < 0.99) return logU(4096, 65536);
  return logU(65536, 1 << 20);
}

// Each block: first and last word hold a check value. Checked on free and on realloc.
const tag = new Map(); // ptr -> {len, id}
let nextId = 1, bad = 0, req = 0, peakReq = 0;
const mark = (p, len, id) => { const m = memv(); m[p >> 2] = id; if (len >= 8) m[(p + len - 4) >> 2] = id ^ 0x5a5a5a5a; tag.set(p, { len, id }); req += len + 16; peakReq = Math.max(peakReq, req); };
const verify = (p) => { const t = tag.get(p); const m = memv(); req -= t.len + 16; if (m[p >> 2] !== t.id || (t.len >= 8 && m[(p + t.len - 4) >> 2] !== (t.id ^ 0x5a5a5a5a))) bad++; tag.delete(p); };
// H8: waste per class (capacity - header - requested)
const waste = new Map();
const noteWaste = (p, len) => { const cap = memv()[(p - 16) >> 2]; const k = cap <= 4096 ? cap : 'large'; const w = waste.get(k) ?? { n: 0, req: 0, cap: 0 }; w.n++; w.req += len + 16; w.cap += cap; waste.set(k, w); };

let peakLive = 0, allocs = 0;
function alloc(len, owner) {
  const p = x.h_alloc(len, owner);
  if (p === 0) throw new Error('oom');
  allocs++; mark(p, len, nextId++); noteWaste(p, len);
  peakLive = Math.max(peakLive, x.h_live());
  return p;
}

const TASKS = +tasksArg, CONC = 32;
let started = 0, done = 0, traps = 0, ownerId = 1;
const active = [];
const pinned = [];
const newTask = () => ({ owner: ownerId++, blocks: [], ops: 5 + Math.floor(rnd() * 55), phase: started++ < TASKS / 2 ? 0 : 1 });
for (let i = 0; i < CONC; i++) active.push(newTask());
process.on("uncaughtException",(e)=>{console.log("$v crash", String(e).slice(0,50), "memMB", x.memory.buffer.byteLength/1048576, "end", x.h_end());process.exit(0)});
const t0 = performance.now();
while (done < TASKS) {
  const i = Math.floor(rnd() * active.length);
  const t = active[i];
  const r = rnd();
  if (t.ops-- <= 0) {
    if (rnd() < 0.01) { traps++; x.h_free_owner(t.owner); for (const b of t.blocks) verify(b.p); }
    else for (const b of t.blocks) { verify(b.p); x.h_free(b.p); }
    done++;
    if (started < TASKS) active[i] = newTask();
    else { active[i] = active[active.length - 1]; active.pop(); }
    if (active.length === 0) break;
    continue;
  }
  if (r < 0.55 || t.blocks.length === 0) {
    if (rnd() < 0.002) { // host cache block (owner 0), lives long
      pinned.push(alloc(logU(64, 4096), 0));
      if (pinned.length > 200) { const k = Math.floor(rnd() * pinned.length); const p = pinned[k]; pinned[k] = pinned[pinned.length - 1]; pinned.pop(); verify(p); x.h_free(p); }
    } else { const len = size(t.phase); t.blocks.push({ p: alloc(len, t.owner), len }); }
  } else if (r < 0.70) { // list grows by doubling (realloc)
    const b = t.blocks[Math.floor(rnd() * t.blocks.length)];
    const len = Math.min(b.len * 2, 1 << 21);
    const old = tag.get(b.p); verify(b.p);
    const p = x.h_realloc(b.p, len, t.owner);
    if (p === 0) throw new Error('oom');
    if (memv()[p >> 2] !== old.id) bad++; // the copy kept the first word
    b.p = p; b.len = len; mark(p, len, nextId++); allocs++;
    peakLive = Math.max(peakLive, x.h_live());
  } else {
    const k = Math.floor(rnd() * t.blocks.length);
    const b = t.blocks[k]; t.blocks[k] = t.blocks[t.blocks.length - 1]; t.blocks.pop();
    verify(b.p); x.h_free(b.p);
  }
}
const ms = performance.now() - t0;
const pinnedBytes = x.h_live();
for (const p of pinned) { verify(p); x.h_free(p); }
const heap = x.h_end() - x.h_start();
const out = { v, profile, seed: +seedArg, step: +stepArg, allocs, traps, bad, ms: +ms.toFixed(0),
  heapMB: +(heap / 1048576).toFixed(2), peakLiveMB: +(peakLive / 1048576).toFixed(2), ratio: +(heap / peakLive).toFixed(2), peakReqMB: +(peakReq / 1048576).toFixed(2), heapPerReq: +(heap / peakReq).toFixed(2),
  nextAfterMB: +((x.h_next() - x.h_start()) / 1048576).toFixed(2), liveEnd: x.h_live(), pinnedKB: +(pinnedBytes / 1024).toFixed(0),
  grows: x.h_grows(), walks: x.h_walks(), walkGainMB: +(x.h_walk_gain() / 1048576).toFixed(2), splits: x.h_splits(), joins: x.h_joins(), tops: x.h_tops() };
if (process.env.WASTE) out.waste = Object.fromEntries([...waste].map(([k, w]) => [k, { n: w.n, wastePct: +(100 * (w.cap - w.req) / w.cap).toFixed(1) }]));
console.log(JSON.stringify(out));
if (bad || x.h_live() !== 0) { console.log('FAIL bad', bad, 'live', x.h_live()); process.exit(1); }
if (process.env.DEBUG) {
  const m = memv(); let sp = x.h_start(); const owners = new Map();
  while (sp < x.h_next()) { const cap = m[sp >> 2]; if (m[(sp + 8) >> 2] === ((cap ^ 0xC0DE5AFE) >>> 0)) { const o = m[(sp + 4) >> 2]; owners.set(o, (owners.get(o) ?? 0) + cap); } sp += cap; }
  console.log('sealed by owner', [...owners].slice(0, 10), 'tags left', tag.size, 'active', active.length, 'done', done, 'started', started);
}
