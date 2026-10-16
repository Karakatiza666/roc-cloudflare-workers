// A real big package in wasm32: stream (64 KB pushes) and one-shot. Usage: node real.mjs FILE.tar.zst
// Prints the SHA-256 of the output (compare with: zstd -d -c FILE | sha256sum) and the peak memory.
import fs from 'node:fs'; import crypto from 'node:crypto';
import { load, le32, OP } from './lib.mjs';
const z = fs.readFileSync(process.argv[2]);
const w = await load('native-small.wasm'); const x = w.x; const u8 = () => new Uint8Array(w.mem.buffer);
// stream, 64 KB pushes, hash the output with node sha256 (not in wasm), peak live
w.task(1); x.h_peak_reset(); const base = x.h_live();
const h = w.handle(w.call(OP.zstd_stream_open)); const sha = crypto.createHash('sha256'); let total = 0, maxPush = 0, tcall = 0;
const pin = x.h_in(4 + 65536);
for (let i = 0; i < z.length; i += 65536) { const part = z.subarray(i, i + 65536); u8().set(le32(h), pin); u8().set(part, pin + 4);
  const a = performance.now(); const st = x.h_call(OP.zstd_stream_push, pin, 4 + part.length); tcall += performance.now() - a;
  if (st) throw new Error('push failed'); const n = x.h_res_len(); total += n; maxPush = Math.max(maxPush, n); sha.update(u8().subarray(x.h_res_ptr(), x.h_res_ptr() + n)); x.h_res_release(); }
w.call(OP.zstd_stream_close, le32(h)); x.h_free(pin);
console.log('stream: out', total, 'sha', sha.digest('hex'), 'ms', tcall.toFixed(0), 'MB/s', (total / 1e6 / (tcall / 1000)).toFixed(0), 'peak live MB', ((x.h_peak() - base) / 1048576).toFixed(1), 'max push out KB', maxPush >> 10, 'mem MB', (w.mem.buffer.byteLength / 1048576) | 0);
x.h_end_trap(1);
// one-shot: should not fit the 128 MB budget
const live0 = x.h_live(); w.task(2);
const r = w.call(OP.zstd_decode, Buffer.concat([le32(200 << 20), z]));
console.log('one-shot: status', r.status, r.bytes.length < 100 ? r.bytes.toString() : r.bytes.length, 'denied grows', w.stats.denied);
x.h_end_trap(2);
console.log('live back to start:', x.h_live() === live0, 'check', x.h_check(), 'miss', x.h_miss());
