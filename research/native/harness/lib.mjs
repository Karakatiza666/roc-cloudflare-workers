// Load the harness wasm and give the op calls as JS functions. The memory budget is the 128 MB of an isolate.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const DATA = path.join(HERE, '..', 'data');
export const OUT = path.join(HERE, '..', 'out');
export const OP = { zstd_decode: 1, zstd_stream_open: 2, zstd_stream_push: 3, zstd_stream_close: 4,
  blake3_new: 5, blake3_update: 6, blake3_final: 7, sha256_new: 8, sha256_update: 9, sha256_final: 10 };
export const BUDGET = 128 << 20;

export function data(name) { return fs.readFileSync(path.join(DATA, name)); }
export function le32(v) { const b = Buffer.alloc(4); b.writeUInt32LE(v >>> 0); return b; }

export async function load(file = 'native-small.wasm') {
  let mem;
  const stats = { grows: 0, denied: 0 };
  const { instance } = await WebAssembly.instantiate(fs.readFileSync(path.join(OUT, file)), {
    env: { js_grow(pages) { // the isolate budget (PLAN.md M3, M4)
      if (mem.buffer.byteLength + pages * 65536 > BUDGET) { stats.denied++; return 0; }
      stats.grows++; return 1; } },
  });
  const x = instance.exports;
  mem = x.memory;
  const u8 = () => new Uint8Array(mem.buffer);
  const api = {
    x, stats, mem,
    task(owner) { x.h_task(owner); },
    /** One op. Returns { status, bytes } with the bytes copied out and the result released. */
    call(op, input = new Uint8Array(0)) {
      const p = x.h_in(Math.max(input.length, 1));
      if (!p) throw new Error('host block: out of memory');
      u8().set(input, p);
      const status = x.h_call(op, p, input.length);
      x.h_free(p);
      const bytes = Buffer.from(u8().slice(x.h_res_ptr(), x.h_res_ptr() + x.h_res_len()));
      x.h_res_release();
      return { status, bytes };
    },
    code(r) { return r.bytes.toString(); },
    handle(r) { if (r.status !== 0) throw new Error('op failed: ' + r.bytes); return r.bytes.readUInt32LE(0); },
    streamAll(owner, z, chunk, openArgs = Buffer.alloc(0)) {
      api.task(owner);
      const h = api.handle(api.call(OP.zstd_stream_open, openArgs));
      const parts = [];
      for (let i = 0; i < z.length; i += chunk) {
        const r = api.call(OP.zstd_stream_push, Buffer.concat([le32(h), z.subarray(i, i + chunk)]));
        if (r.status !== 0) { api.call(OP.zstd_stream_close, le32(h)); return { error: api.code(r) }; }
        parts.push(r.bytes);
      }
      const c = api.call(OP.zstd_stream_close, le32(h));
      if (c.status !== 0) return { error: api.code(c) };
      return { bytes: Buffer.concat(parts) };
    },
    hashChunks(owner, kind, buf, chunk) {
      api.task(owner);
      const [n, u, f] = kind === 'blake3' ? [OP.blake3_new, OP.blake3_update, OP.blake3_final] : [OP.sha256_new, OP.sha256_update, OP.sha256_final];
      const h = api.handle(api.call(n));
      for (let i = 0; i < buf.length; i += chunk) api.call(u, Buffer.concat([le32(h), buf.subarray(i, i + chunk)]));
      return api.call(f, le32(h)).bytes.toString('hex');
    },
  };
  return api;
}
