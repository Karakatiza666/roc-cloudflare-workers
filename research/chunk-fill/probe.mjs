// Probe: WORKERD=<path> node research/chunk-fill/probe.mjs. A Node server gives 110 MB (fetch source); a POST sends
// 110 MB (request source). Prints the parts and the fills of each mode of probe-worker.js.
import { spawn } from 'node:child_process';
import http from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const TOTAL = 110 * 2 ** 20;
const block = new Uint8Array(65536).fill(7);
const srv = http.createServer((req, res) => {
  res.writeHead(200, { 'content-length': TOTAL });
  let sent = 0;
  const pump = () => { while (sent < TOTAL) { const n = Math.min(65536, TOTAL - sent); sent += n; if (!res.write(block.subarray(0, n))) return res.once('drain', pump); } res.end(); };
  pump();
}).listen(8192);
const p = spawn(process.env.WORKERD, ['serve', join(here, 'probe.capnp')], { stdio: ['ignore', 'inherit', 'inherit'] });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
for (let i = 0; i < 100; i++) { await sleep(100); if (await fetch('http://127.0.0.1:8191/ping').then(() => true, () => false)) break; }
function bodyStream() { let sent = 0; return new ReadableStream({ pull(c) { if (sent >= TOTAL) return c.close(); const n = Math.min(65536, TOTAL - sent); c.enqueue(block.slice(0, n)); sent += n; } }); }
for (const src of ['fetch', 'req']) for (const how of ['each', 'none', 'micro', 'timer']) {
  const t0 = performance.now();
  const q = `http://127.0.0.1:8191/probe?src=${src}&how=${how}&target=65536&url=http://127.0.0.1:8192/big`;
  const r = src === 'fetch' ? await fetch(q) : await fetch(q, { method: 'POST', body: bodyStream(), duplex: 'half' });
  console.log(src, JSON.stringify(await r.json()), `${Math.round(performance.now() - t0)} ms`);
}
p.kill(); srv.close();
