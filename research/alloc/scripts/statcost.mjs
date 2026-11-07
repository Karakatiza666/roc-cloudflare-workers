// The cost of the stats counters (research/alloc/README.md 6). Runs the same app on two builds, interleaved:
//   node research/alloc/scripts/statcost.mjs <base.wasm> <new.wasm> [items=200] [requests=3000] [rounds=9]
// base.wasm: a build with the host before the counters (HEAD of the platform at the time). new.wasm: the host with the counters.
// Rows: base; new, option off; new, option on (the header, JSON, a Response copy only when the headers are locked).
// Output: the median of the rounds, in µs per request, and the spread. Needs the stand-in of cloudflare:workers (bench/cf-node.mjs).
import { readFileSync } from 'node:fs';
const { makeHandler } = await import('../../../bench/cf-node.mjs');
const { benchOps } = await import('../../../bench/ops.js');
const [baseFile, newFile, items = 200, reqs = 3000, rounds = 9] = process.argv.slice(2);
const mods = { base: new WebAssembly.Module(readFileSync(baseFile)), new: new WebAssembly.Module(readFileSync(newFile)) };
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const rows = [
  ['base', 'base', {}],
  ['new, stats off', 'new', {}],
  ['new, stats on', 'new', { stats: true }],
];
const once = async (mod, opts) => {
  const H = makeHandler(mods[mod], { ops: benchOps(io), isolateBytes: 2 ** 40, ...opts });
  const h = new H({}, {});
  const req = (i) => new Request('http://x/', { method: 'POST', body: `${i} 0 ${items}` });
  for (let i = 0; i < 300; i++) await (await h.fetch(req(i))).text(); // warm-up: the wasm tier-up is not timed
  const t = performance.now();
  for (let i = 0; i < reqs; i++) await (await h.fetch(req(i))).text();
  return ((performance.now() - t) * 1000) / reqs;
};
const res = rows.map(() => []);
for (let r = 0; r < rounds; r++) for (let k = 0; k < rows.length; k++) res[(k + r) % rows.length].push(await once(rows[(k + r) % rows.length][1], rows[(k + r) % rows.length][2]));
console.table(
  rows.map(([name], k) => {
    const s = [...res[k]].sort((a, b) => a - b);
    return { build: name, medianUs: +s[s.length >> 1].toFixed(1), minUs: +s[0].toFixed(1), maxUs: +s[s.length - 1].toFixed(1) };
  }),
);
