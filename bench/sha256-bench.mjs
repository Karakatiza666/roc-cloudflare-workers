// PLAN.md 8c (measure for 8g): `Crypto.SHA256.hash` (the builtin of Roc, in wasm) against `crypto.subtle.digest` (native
// code after a copy, and a promise) for 1 KB, 64 KB and 1 MB, in Node with the runner of `../js/`.
//   node bench/sha256-bench.mjs bench/out/conformance.wasm
// The route `/webcrypto/sha256?size=<bytes>&n=<count>` of `conformance/WebCryptoRoutes.roc` hashes `n` buffers of `size`
// bytes (the first byte changes each time) in one request, and answers the hex of the last digest. The time of one hash is
// (time of a request with n hashes, less the time of a request with 0 hashes) / n: the request and the buffer cancel.
// Each number is the median of 5 runs. The first line of each size checks the answer against Node `crypto`.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { makeHandler } from './cf-node.mjs';

const module = new WebAssembly.Module(readFileSync(process.argv[2] ?? 'bench/out/conformance.wasm'));
const Handler = makeHandler(module, {});
const env = {};
const ctx = { waitUntil() {} };
const request = async (path) => {
  const t0 = performance.now();
  const res = await new Handler(ctx, env).fetch(new Request(`http://x${path}`));
  const body = await res.text();
  return { ms: performance.now() - t0, body };
};
const median = (xs) => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];

const sizes = [
  { label: '1 KB', size: 1024, n: 20000 },
  { label: '4 KB', size: 4096, n: 5000 },
  { label: '16 KB', size: 16384, n: 2000 },
  { label: '64 KB', size: 65536, n: 1000 },
  { label: '1 MB', size: 1048576, n: 60 },
];
const rows = [];
for (const { label, size, n } of sizes) {
  // The answer is right: the last buffer has the first byte (n - 1) % 256, the others 7.
  const buf = Buffer.alloc(size, 7);
  buf[0] = (n - 1) % 256;
  const want = createHash('sha256').update(buf).digest('hex');
  const check = await request(`/webcrypto/sha256?size=${size}&n=${n}`);
  if (check.body !== want) {
    console.log(`FAIL ${label}: the digest differs: got ${check.body}, want ${want}`);
    process.exit(1);
  }
  const wasm = [];
  const native = [];
  for (let run = 0; run < 5; run++) {
    const base = (await request(`/webcrypto/sha256?size=${size}&n=0`)).ms;
    wasm.push(((await request(`/webcrypto/sha256?size=${size}&n=${n}`)).ms - base) / n);
    // `digest` of the same buffers: a copy of the input and a promise for each call.
    const t0 = performance.now();
    for (let i = 0; i < n; i++) {
      buf[0] = i % 256;
      await crypto.subtle.digest('SHA-256', buf);
    }
    native.push((performance.now() - t0) / n);
  }
  rows.push({ label, wasm_us: Math.round(median(wasm) * 1000 * 10) / 10, digest_us: Math.round(median(native) * 1000 * 10) / 10 });
}
console.log('| Size | Crypto.SHA256.hash (wasm) us | crypto.subtle.digest us | wasm / digest |');
console.log('| --- | --- | --- | --- |');
for (const r of rows) console.log(`| ${r.label} | ${r.wasm_us} | ${r.digest_us} | ${(r.wasm_us / r.digest_us).toFixed(1)} |`);
process.exit(0);
