// PLAN.md 6a: host-owned allocations (the log) use owner 0.
// node bench/log-test.mjs bench/out/app.wasm
// 400 requests in 4 rounds of 100 at once (the host has 255 task slots): 200 write 200 `dbg`
// lines and then crash, 200 are good.
// Expect: 0 bad bodies, all dbg requests trap clean, 200 x 200 log lines read, and (8b, the crash text of 8a O2)
// one crash line of level 0 for each dbg request, with its text,
// live bytes 0, dealloc_miss 0, no retired instance.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  if (kind === 1) { await sleep(2); return 'f:' + new URL(b).searchParams.get('id'); }
  await sleep(1); return 'd:' + a.split(' ')[1];
};
const N = 200, LINES = 200, DEPTH = 5;
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const seen = new Map(); // id -> line numbers read
let junk = 0;
const crashes = new Set(); // ids of the crash lines (level 0)
const onLog = (level, text) => {
  const c = /^crash after dbg of request (\d+)$/.exec(text);
  if (c && level === 0) { crashes.add(c[1]); return; }
  const m = /request (\d+) line (\d+)/.exec(text);
  if (!m || level !== 1) { junk++; return; }
  if (!seen.has(m[1])) seen.set(m[1], new Set());
  seen.get(m[1]).add(Number(m[2]));
};
const r = makeRunner(module, io, { onLog, isolateBytes: 2 ** 40 });
const reqs = [];
for (let i = 0; i < 2 * N; i++) {
  const dbg = i % 2 === 0;
  reqs.push({ id: String(5000 + i), dbg, req: `${5000 + i} 0 ${DEPTH} 10${dbg ? ' dbg' : ''}` });
}
const res = [];
for (let i = 0; i < reqs.length; i += 100) res.push(...(await Promise.all(reqs.slice(i, i + 100).map((q) => r.run(q.req)))));
let bad = 0, trapped = 0;
res.forEach((x, i) => {
  const q = reqs[i];
  if (q.dbg) { if (x.trap && x.crash === `crash after dbg of request ${q.id}`) trapped++; else bad++; } else if (x.trap || !check(q.id, x.body, DEPTH)) bad++;
});
let complete = 0;
let crashed = 0;
for (const q of reqs) if (q.dbg && seen.get(q.id)?.size === LINES) complete++;
for (const q of reqs) if (q.dbg && crashes.has(q.id)) crashed++;
const x = r.x;
const live = x.live_bytes(), miss = x.dealloc_miss(), logLen = x.log_len();
console.log({ bad, trapped, complete, crashed, junk, freed: r.stats.freed, walkFailed: r.stats.walkFailed, retired: r.stats.retired, live, miss, logLen });
if (bad !== 0) fail('bad bodies');
if (trapped !== N) fail('dbg requests must trap, with the crash text in the result');
if (complete !== N || junk !== 0) fail('log lines missing or wrong');
if (crashed !== N || crashes.size !== N) fail('crash lines missing or wrong');
if (r.stats.walkFailed !== 0 || r.stats.retired !== 0) fail('a trap was not clean');
if ((live !== 0 || miss !== 0 || logLen !== 0)) fail('live bytes, dealloc_miss or log not 0');
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
