// CPU cost in Node (V8, real clock): node bench/micro.mjs bench/out/app.wasm bench/out/app_pad.wasm
// 1. new WebAssembly.Instance alone, and with init(), real and padded module.
// 2. The copy work of one wait alone, by size.
// 3. Per-request cost of the shared instance with and without the copy, waits that resolve at once (no I/O), by depth.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';

const mods = { real: new WebAssembly.Module(readFileSync(process.argv[2])), pad: new WebAssembly.Module(readFileSync(process.argv[3])) };
const env = { env: { js_await: new WebAssembly.Suspending(async () => 0), js_call: () => 0, js_grow: () => 1 } };

function instUs(m, n, withInit) {
  const t = performance.now();
  for (let i = 0; i < n; i++) {
    const x = new WebAssembly.Instance(m, env).exports;
    if (withInit) x.init(0);
  }
  return +(((performance.now() - t) * 1000) / n).toFixed(1);
}
for (const [k, m] of Object.entries(mods)) {
  instUs(m, 200, true);
  const r = [1, 2, 3].map(() => [instUs(m, 1000, false), instUs(m, 1000, true)]);
  console.log(JSON.stringify({ module: k, bytes: readFileSync(process.argv[k === 'real' ? 2 : 3]).length, instanceUs: r.map((x) => x[0]), instancePlusInitUs: r.map((x) => x[1]) }));
}

const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
let id = 1;
// Mean µs per request over n requests, `conc` at a time. mode: b, or nocopy
// (the shared instance with the copy off, sound only with conc 1).
async function perReq(mode, depth, conc, n, items = 200) {
  const r = makeRunner(mods.real, io);
  if (mode === 'nocopy') r.x.set_copy(0);
  const go = async () => {
    let bad = 0;
    for (let done = 0; done < n; done += conc) {
      const ids = Array.from({ length: conc }, () => String(id++));
      const res = await Promise.all(ids.map((k) => r.run(`${k} 0 ${depth} ${items}`)));
      res.forEach((x, i) => { if (!check(ids[i], x.body ?? '', depth)) bad++; });
    }
    return bad;
  };
  await go(); // warmup
  if (mode === 'b') r.x.stats_reset();
  const t = performance.now();
  const bad = await go();
  const us = ((performance.now() - t) * 1000) / n;
  return { us, bad, savedMax: mode === 'b' ? r.x.task_saved_max() : 0, savedPeak: mode === 'b' ? r.x.task_saved_peak() : 0 };
}
// 2. The copy work alone (host export copy_bench): one wait = alloc, copy out, copy back, free.
{
  const x = makeRunner(mods.real, io).x;
  for (const kb of [1, 2, 16, 64, 256, 720]) {
    const len = kb * 1024, it = Math.max(200, Math.floor(2e8 / len));
    x.copy_bench(len, 100);
    const r = [1, 2, 3].map(() => {
      const t = performance.now();
      x.copy_bench(len, it);
      return +(((performance.now() - t) * 1000) / it).toFixed(3);
    });
    console.log(JSON.stringify({ copyBenchKB: kb, usPerWait: r, gbPerS: +((2 * len) / (Math.min(...r) * 1000)).toFixed(1) }));
  }
}

// 3. Whole requests at each depth. ITEMS=0 drops the JSON work, so the copy share shows.
const ITEMS = Number(process.env.ITEMS ?? 200);
const DEPTHS = (process.env.DEPTHS || '0,30,130,530').split(',').map(Number);
const N = 2048;
const med = (a) => [...a].sort((x, y) => x - y)[1];
for (const depth of DEPTHS) {
  const t = { b: [], nocopy: [] };
  let bad = 0, savedMax = 0;
  for (let k = 0; k < 3; k++) {
    for (const mode of ['nocopy', 'b']) {
      const r = await perReq(mode, depth, 1, N, ITEMS);
      t[mode].push(r.us);
      bad += r.bad;
      savedMax = Math.max(savedMax, r.savedMax);
    }
  }
  const b64 = await perReq('b', depth, 64, N, ITEMS);
  console.log(JSON.stringify({
    items: ITEMS, depth, stackBytesPerWait: savedMax,
    usPerReq: { nocopy: t.nocopy.map((x) => +x.toFixed(1)), b: t.b.map((x) => +x.toFixed(1)) },
    usPerWaitCopy: +((med(t.b) - med(t.nocopy)) / 2).toFixed(2),
    conc64: { bUs: +b64.us.toFixed(1), bSavedPeak: b64.savedPeak },
    bad: bad + b64.bad,
  }));
}
