// Measure (research/chunk-fill/README.md): `Body.chunk_with!` over a 110 MB request body, with fill 1 (one part for
// each call, as `chunk!` before) and larger fill targets. The app is bench/out/app_stream.wasm (`POST /chunk`).
// Node: makeHandler of bench/cf-node.mjs, a body in parts of 4 KiB and of 64 KiB. workerd: bench/config-stream.capnp
// (port 8136), a raw POST (workerd gives the request body in parts of about 4 KiB).
// WORKERD=<path> node research/chunk-fill/measure.mjs bench/out/app_stream.wasm
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeHandler } from '../../bench/cf-node.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const TOTAL = 110 * 2 ** 20;
const FILLS = [1, 16384, 65536, 262144];
const RUNS = 3;
const block = new Uint8Array(65536).fill(7);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const stream = (part) => {
  let sent = 0;
  return new ReadableStream({
    pull(c) {
      if (sent >= TOTAL) return c.close();
      const n = Math.min(part, TOTAL - sent);
      c.enqueue(block.slice(0, n));
      sent += n;
    },
  });
};
const best = async (f) => {
  let out;
  for (let i = 0; i < RUNS; i++) {
    const t0 = performance.now();
    const text = await f();
    const ms = performance.now() - t0;
    if (!out || ms < out.ms) out = { ms, text };
  }
  return out;
};
const row = (where, fill, { ms, text }) => console.log(`| ${where} | ${fill} | ${text.replace(/chunks=(\d+) bytes=(\d+)/, '$1 | $2')} | ${Math.round(ms)} |`);
console.log('| Where | fill_bytes | Chunks (crossings) | Bytes | ms (best of 3) |\n| --- | --- | --- | --- | --- |');

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const H = makeHandler(module, { isolateBytes: 2 ** 40, heapCheckWhenIdle: false });
const ctx = { waitUntil() {}, passThroughOnException() {} };
const post = (path, body) => new H(ctx, { name: 'env' }).fetch(new Request(`http://x${path}`, { method: 'POST', body, duplex: 'half' }));
for (const part of [4096, 65536]) for (const fill of FILLS) {
  row(`Node, parts of ${part} B`, fill, await best(async () => (await post(`/chunk?n=${TOTAL}&fill=${fill}`, stream(part))).text()));
}

const PORT = 8136;
function rawPost(path) {
  return new Promise((resolve, reject) => {
    const s = net.connect(PORT, '127.0.0.1');
    let got = Buffer.alloc(0), sent = 0;
    const pump = () => {
      while (sent < TOTAL) {
        const n = Math.min(65536, TOTAL - sent);
        sent += n;
        if (!s.write(block.subarray(0, n))) return s.once('drain', pump);
      }
    };
    s.on('connect', () => (s.write(`POST ${path} HTTP/1.1\r\nHost: x\r\nContent-Length: ${TOTAL}\r\n\r\n`), pump()));
    s.on('data', (d) => {
      got = Buffer.concat([got, d]);
      const at = got.indexOf('\r\n\r\n');
      const len = at < 0 ? NaN : Number(/content-length: *(\d+)/i.exec(got.subarray(0, at).toString())?.[1]);
      if (got.length >= at + 4 + len) (s.destroy(), resolve(got.subarray(at + 4, at + 4 + len).toString()));
    });
    s.on('error', reject);
  });
}
const p = spawn(process.env.WORKERD, ['serve', join(here, '../../bench/config-stream.capnp')], { stdio: ['ignore', 'ignore', 'inherit'] });
try {
  for (let i = 0; i < 100; i++) {
    await sleep(100);
    if (await fetch(`http://127.0.0.1:${PORT}/ping`).then((r) => r.ok, () => false)) break;
  }
  for (const fill of FILLS) row('workerd, request body', fill, await best(() => rawPost(`/chunk?n=${TOTAL}&fill=${fill}`)));
} finally {
  p.kill();
}
