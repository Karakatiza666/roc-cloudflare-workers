// Speed, memory and stack of the Native ops in wasm32 (Node, V8 wasm). Usage: node bench.mjs [wasm file] [json]
// Data: data/big-1m.tar.zst and data/big-10m.tar.zst (make-data.sh).
import { load, data, le32, OP } from './lib.mjs';

const file = process.argv[2] || 'native-small.wasm';
const w = await load(file);
const x = w.x;
const u8 = () => new Uint8Array(w.mem.buffer);
const MB = 1e6;
const rows = [];

/** Put bytes in a host block (owner 0). */
function put(buf) { const p = x.h_in(buf.length); u8().set(buf, p); return p; }

function best(n, f) { let b = Infinity; for (let i = 0; i < n; i++) { const t = performance.now(); f(); b = Math.min(b, performance.now() - t); } return b; }

// The stack: paint it, run, find the deepest write. The stack is first (0 .. sp0) in this build.
const sp0 = x.h_sp();
function stackUsed(f) {
  const lo = 2048, hi = sp0 - 1024;
  u8().fill(0xA5, lo, hi);
  f();
  const m = u8();
  let i = lo; while (i < hi && m[i] === 0xA5) i++;
  return sp0 - i;
}

// Decode
for (const [name, label] of [['big-1m.tar.zst', '1 MB'], ['big-10m.tar.zst', '10 MB']]) {
  const z = data(name);
  const inp = put(Buffer.concat([le32(100 << 20), z]));
  w.task(1);
  x.h_peak_reset();
  const base = x.h_live();
  const memBefore = w.mem.buffer.byteLength;
  let outLen = 0, status = 0;
  const run = () => { status = x.h_call(OP.zstd_decode, inp, z.length + 4); outLen = x.h_res_len(); x.h_res_release(); };
  const t = best(3, run);
  const peak = x.h_peak() - base;
  const stack = stackUsed(run);
  x.h_end_trap(1);
  rows.push({ op: `zstd_decode ${label} .tar.zst`, in: z.length, out: outLen, status, ms: t, mbps_out: outLen / MB / (t / 1000), mbps_in: z.length / MB / (t / 1000), peak, stack, mem: w.mem.buffer.byteLength });

  // The stream, chunks of 64 KB
  w.task(1);
  x.h_peak_reset();
  const base2 = x.h_live();
  const t0 = performance.now();
  const h = w.handle(w.call(OP.zstd_stream_open));
  let total = 0, maxPush = 0;
  const CH = 65536;
  const chunkBuf = Buffer.alloc(4 + CH);
  le32(h).copy(chunkBuf, 0);
  const pin = x.h_in(4 + CH);
  let tcall = 0;
  for (let i = 0; i < z.length; i += CH) {
    const part = z.subarray(i, i + CH);
    u8().set(le32(h), pin); u8().set(part, pin + 4);
    const a = performance.now();
    const st = x.h_call(OP.zstd_stream_push, pin, 4 + part.length);
    tcall += performance.now() - a;
    if (st !== 0) throw new Error('stream push failed');
    total += x.h_res_len(); maxPush = Math.max(maxPush, x.h_res_len());
    x.h_res_release();
  }
  const peak2 = x.h_peak() - base2;
  const c = w.call(OP.zstd_stream_close, le32(h));
  x.h_free(pin);
  x.h_end_trap(1);
  rows.push({ op: `zstd stream ${label} (push 64 KB)`, in: z.length, out: total, status: c.status, ms: tcall, mbps_out: total / MB / (tcall / 1000), mbps_in: z.length / MB / (tcall / 1000), peak: peak2, stack: null, mem: w.mem.buffer.byteLength, extra: `max push out ${maxPush}` });
  x.h_free(inp);
}

// Hashes: 64 KB chunks, 160 MB in all
for (const kind of ['blake3', 'sha256']) {
  const CH = 65536, N = 2500;
  w.task(1);
  const h = w.handle(w.call(kind === 'blake3' ? OP.blake3_new : OP.sha256_new));
  const chunk = Buffer.alloc(4 + CH);
  le32(h).copy(chunk, 0);
  for (let i = 4; i < chunk.length; i++) chunk[i] = (i * 2654435761) >>> 24;
  const p = put(chunk);
  const upd = kind === 'blake3' ? OP.blake3_update : OP.sha256_update;
  const t = best(3, () => { for (let i = 0; i < N; i++) x.h_call(upd, p, chunk.length); });
  const stack = stackUsed(() => x.h_call(upd, p, chunk.length));
  x.h_free(p);
  x.h_end_trap(1);
  rows.push({ op: `${kind} update, 64 KB chunks`, in: CH * N, out: 32, status: 0, ms: t, mbps_in: CH * N / MB / (t / 1000), peak: null, stack, mem: w.mem.buffer.byteLength });
}

console.log(`build ${file}, stack top ${sp0}, memory ${(w.mem.buffer.byteLength / 1048576).toFixed(0)} MB at the end`);
console.log('| Op | In (B) | Out (B) | ms | MB/s out | MB/s in | Peak live (KB) | Stack (KB) |');
console.log('| --- | --- | --- | --- | --- | --- | --- | --- |');
for (const r of rows) {
  console.log(`| ${r.op} | ${r.in} | ${r.out} | ${r.ms.toFixed(1)} | ${r.mbps_out ? r.mbps_out.toFixed(0) : '-'} | ${r.mbps_in.toFixed(0)} | ${r.peak == null ? '-' : (r.peak / 1024).toFixed(0)} | ${r.stack == null ? '-' : (r.stack / 1024).toFixed(0)} |` + (r.extra ? ` ${r.extra}` : ''));
}
