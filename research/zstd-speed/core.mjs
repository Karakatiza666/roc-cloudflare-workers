// The probe loop, for Node (run.mjs) and workerd (worker.mjs). It drives the Native ops of the harness
// (research/native/harness/harness.zig): open a stream, push the input in `chunk` byte pieces, close.
// `onOut(bytes)` (optional) gets a view of the output of each push (verify mode). Timing mode passes none.
export const OP = { zstd_decode: 1, zstd_stream_open: 2, zstd_stream_push: 3, zstd_stream_close: 4 };
const le32 = (u8, at, v) => { u8[at] = v & 255; u8[at + 1] = (v >>> 8) & 255; u8[at + 2] = (v >>> 16) & 255; u8[at + 3] = (v >>> 24) & 255; };
const BUDGET = 128 << 20;

export async function instantiate(module) {
  let mem;
  const stats = { grows: 0, denied: 0 };
  const inst = await WebAssembly.instantiate(module, {
    env: { js_grow(pages) { if (mem.buffer.byteLength + pages * 65536 > BUDGET) { stats.denied++; return 0; } stats.grows++; return 1; } },
  });
  const x = (inst.instance ?? inst).exports;
  mem = x.memory;
  return { x, stats };
}

/** Returns { out, status, code, maxPush, peakLive }. */
export function stream({ x }, z, chunk, owner, onOut) {
  const u8 = () => new Uint8Array(x.memory.buffer);
  const call = (op, p, n) => x.h_call(op, p, n);
  const code = () => new TextDecoder().decode(u8().slice(x.h_res_ptr(), x.h_res_ptr() + x.h_res_len()));
  x.h_task(owner);
  x.h_peak_reset();
  const base = x.h_live();
  const pin = x.h_in(4 + chunk);
  let st = call(OP.zstd_stream_open, pin, 0);
  if (st) { const c = code(); x.h_res_release(); return { status: st, code: c }; }
  const h = new DataView(x.memory.buffer).getUint32(x.h_res_ptr(), true);
  x.h_res_release();
  let out = 0, maxPush = 0, err = null;
  for (let i = 0; i < z.length; i += chunk) {
    const part = z.subarray(i, i + chunk);
    const m = u8(); le32(m, pin, h); m.set(part, pin + 4);
    st = call(OP.zstd_stream_push, pin, 4 + part.length);
    if (st) { err = code(); x.h_res_release(); break; }
    const n = x.h_res_len();
    out += n; if (n > maxPush) maxPush = n;
    if (onOut) onOut(u8().subarray(x.h_res_ptr(), x.h_res_ptr() + n));
    x.h_res_release();
  }
  le32(u8(), pin, h);
  const cst = call(OP.zstd_stream_close, pin, 4);
  if (!err && cst) err = code();
  x.h_res_release();
  x.h_free(pin);
  const peakLive = x.h_peak() - base;
  x.h_end_trap(owner);
  return { out, status: err ? 1 : 0, code: err, maxPush, peakLive };
}
