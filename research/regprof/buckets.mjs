// Sum the parts of regprof.mjs --perf --json results into the buckets of the report.
// node buckets.mjs <result.json>...
import { readFileSync } from 'node:fs';
const bucket = (p) => {
  if (/database\.worker|d1-api|SQLite|Miniflare|internal_assert|miniflare:/.test(p)) return 'Miniflare and local D1 (not on the edge)';
  if (/^no JS on the stack: (workerd I\/O|kernel|zlib|other)/.test(p)) return 'workerd outside JS (HTTP, RPC, event loop, kernel, gzip)';
  if (/workerd API called from JS/.test(p)) return 'workerd API called by the shim (Request, Response, Headers, D1 and Cache bindings)';
  if (/V8 GC|V8 runtime|V8 compile|lazy compile|wasm calls into V8/.test(p)) return 'V8 (GC, compile, runtime)';
  if (/cbor\.js|values\.js|wasm host CBOR/.test(p)) return 'CBOR codec (shim cbor.js and values.js, host CBOR)';
  if (/shim JS/.test(p)) return 'shim JS (other files)';
  if (/host allocator/.test(p)) return 'allocator (wasm host)';
  if (/global check|host sums/.test(p)) return 'global check and sums (wasm host)';
  if (/wasm host other/.test(p)) return 'wasm host, other';
  if (/wasm Roc/.test(p)) return 'wasm Roc (app code, builtins, refcount)';
  return `other: ${p}`;
};
for (const f of process.argv.slice(2)) {
  const r = JSON.parse(readFileSync(f, 'utf8').trim().split('\n').pop());
  const acc = new Map();
  for (const x of r.rows) acc.set(bucket(x.part), (acc.get(bucket(x.part)) ?? 0) + x.msPerRequest);
  const tot = [...acc.values()].reduce((a, b) => a + b, 0);
  console.log(`${f}: ${r.scenario}${r.first ? ' (first request)' : ''}, ${r.requests} requests, wall median ${r.wallMsMedian} ms, workerd CPU ${r.workerdCpuMs} ms, node CPU ${r.nodeCpuMs} ms per request`);
  for (const [b, ms] of [...acc].sort((a, b) => b[1] - a[1])) console.log(`  ${ms.toFixed(3).padStart(7)} ms ${((100 * ms) / tot).toFixed(1).padStart(5)} %  ${b}`);
}
