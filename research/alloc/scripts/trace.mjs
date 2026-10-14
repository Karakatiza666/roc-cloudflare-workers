// Record the allocator calls of the bench app (build: TRACE=1 build.sh v5).
// node trace.mjs <items> <batches> [conc=64] -> out/trace_<items>_<batches>.bin
// Record: 4 x u32 [op | align << 8 | offset << 16, owner, id, len]. Offset: the pointer
// passed to free or realloc minus the pointer that alloc gave (adopt: in len). Ops: 1 alloc, 2 free, 3 realloc,
// 4 task end, 5 sum (wait), 6 adopt. Ids are reused after a free, so the replay
// table needs only the peak count of live blocks.
import { readFileSync, writeFileSync } from 'node:fs';
const [items, batches, conc = 64] = process.argv.slice(2).map(Number);
let buf = new Uint32Array(1 << 22), n = 0;
const ids = new Map(), freeIds = [];
let nextId = 0, live = 0, maxLive = 0, misses = 0;
const put = (op, owner, id, len) => {
  if (n + 4 > buf.length) { const b = new Uint32Array(buf.length * 2); b.set(buf); buf = b; }
  buf[n++] = op; buf[n++] = owner; buf[n++] = id; buf[n++] = len;
};
const newId = (p) => { const id = freeIds.length ? freeIds.pop() : nextId++; ids.set(p, id); live++; if (live > maxLive) maxLive = live; return id; };
// A pointer inside a block: Roc and js_alloc can pass the block + 4.
const find = (p) => { for (const d of [0, 4, 8, 12, 16]) if (ids.has(p - d)) return p - d; return -1; };
globalThis.jsTrace = (op, owner, a, b, c) => {
  owner >>>= 0; a >>>= 0; b >>>= 0; c >>>= 0;
  const k = op & 0xff;
  if (k === 1) { if (c) put(op, owner, newId(c), b); }
  else if (k === 2) { const p = find(a); if (p < 0) { if (a) misses++; return; } const id = ids.get(p); ids.delete(p); freeIds.push(id); live--; put(2 | ((a - p) << 16), owner, id, 0); }
  else if (k === 3) {
    if (a === 0) { if (c) put(1 | (op & ~0xff), owner, newId(c), b); return; }
    const p = find(a); if (p < 0) { misses++; return; }
    const id = ids.get(p); ids.delete(p); ids.set(c, id); put(op | ((a - p) << 16), owner, id, b);
  }
  else if (k === 6) { const p = find(a); if (p < 0) { misses++; return; } put(6, owner, ids.get(p), a - p); }
  else put(k, owner, 0, 0);
};
const { makeRunner, check } = await import('../harness/bench/core.js');
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const r = makeRunner(new WebAssembly.Module(readFileSync(new URL('../out/app_v5_trace.wasm', import.meta.url))), 'b', io);
r.x.set_sum(1);
let id = 1, bad = 0;
for (let b = 0; b < batches; b++) {
  const qs = Array.from({ length: conc }, () => id++);
  const res = await Promise.all(qs.map((q) => r.run(`${q} 0 50 ${items}`)));
  res.forEach((x, i) => { if (!check(String(qs[i]), x.body ?? '')) bad++; });
}
const out = new URL(`../out/trace_${items}_${batches}.bin`, import.meta.url);
writeFileSync(out, buf.subarray(0, n));
const cnt = [0, 0, 0, 0, 0, 0, 0];
let offs = 0;
for (let i = 0; i < n; i += 4) { cnt[buf[i] & 0xff]++; if (buf[i] >> 16) offs++; }
console.log(out.pathname, { records: n / 4, alloc: cnt[1], free: cnt[2], realloc: cnt[3], taskEnd: cnt[4], sum: cnt[5], adopt: cnt[6], maxLive, ids: nextId, offs, misses, bad });
