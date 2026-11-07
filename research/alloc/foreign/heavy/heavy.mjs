// Heavy long-lived tasks on ONE workerd isolate (research/alloc/foreign/heavy). Closed loop: N tasks at once, a new task
// starts when one ends. Phases of equal time with a different size mix (default s, b, m). One JSON line per response.
//   node heavy.mjs --app out/<v>/app --n 5 --kb 10240 --secs 180 --phases s,b,m --q "waits=4&ms=250" --out out/x.jsonl
// Shim options: stats on, sums and global check off, isolateBytes 128 MB with jsReserveBytes 0, so the wasm limit is
// the 128 MB of the allocator (the production default leaves 80 MB for wasm).
// Line: {i, ph, t0, t1, status, body, mem, livePeak, liveEnd, grows, served} (t0, t1: ms from the start).
import { createWriteStream } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const opt = {};
for (let i = 2; i < process.argv.length; i += 2) opt[process.argv[i].slice(2)] = process.argv[i + 1];
const app0 = resolve(opt.app);
const n = Number(opt.n ?? 5), kb = Number(opt.kb ?? 5120), secs = Number(opt.secs ?? 180);
const phases = (opt.phases ?? 's,b,m').split(',');
const extra = opt.q ?? 'waits=4&ms=250';
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
process.env.CFW_TEST_OPTIONS = JSON.stringify({ stats: true, resumeCheck: 'off', heapCheckEvery: 0, heapCheckWhenIdle: false, isolateBytes: 128 * 2 ** 20, jsReserveBytes: 0 });

const { startApp } = await import(pathToFileURL(join(app0, '.roc-cfw', 'test.mjs')).href);
const app = await startApp({ dir: app0, miniflare: mfDir });
const out = createWriteStream(opt.out);
const T = Date.now();
const end = T + secs * 1000;
let next = 0, bad = 0, done = 0, maxMem = 0, inRow = 0;
// 100 failures in a row: the isolate does not recover (the fa backends leak the blocks of a trapped task): stop the run.
const STUCK = 100;
const worker = async () => {
  while (Date.now() < end && inRow < STUCK) {
    const i = next++;
    const ph = Math.min(phases.length - 1, Math.floor(((Date.now() - T) / (secs * 1000)) * phases.length));
    const t0 = Date.now() - T;
    let r = { status: 0 };
    try {
      const res = await app.fetch(`/?kb=${kb}&mix=${phases[ph]}&seed=${i + 1}&${extra}`);
      const body = await res.text();
      const st = res.headers.get('x-roc-stats');
      const s = st ? JSON.parse(st) : {};
      r = { status: res.status, body: body.slice(0, 120), mem: s.mem, livePeak: s.livePeak, liveEnd: s.liveEnd, grows: s.grows, served: s.served };
    } catch (e) {
      r = { status: 0, body: String(e.message ?? e).slice(0, 200) };
    }
    if (r.status !== 200) { bad++; inRow++; } else inRow = 0;
    if (r.mem > maxMem) maxMem = r.mem;
    out.write(JSON.stringify({ i, ph, t0, t1: Date.now() - T, ...r }) + '\n');
    if (++done % 50 === 0) console.error(`${done} ${((Date.now() - T) / 1000).toFixed(0)} s mem ${(maxMem / 2 ** 20).toFixed(1)} MB bad ${bad}`);
  }
};
await Promise.all(Array.from({ length: n }, worker));
await new Promise((r) => out.end(r));
console.error(`done ${done} tasks, ${bad} bad${inRow >= STUCK ? ' (stuck: stopped)' : ''}, max mem ${(maxMem / 2 ** 20).toFixed(2)} MB`);
await app.close().catch(() => {});
process.exit(0);
