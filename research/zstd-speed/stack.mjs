// Stack use of the zstd ops of a probe wasm (the stack is first in memory: 0 .. sp). Paint, run, find the deepest write.
// Usage: node stack.mjs <wasm> <file.zst>
import { readFileSync } from 'node:fs';
import { instantiate, stream } from './core.mjs';
const w = await instantiate(new WebAssembly.Module(readFileSync(process.argv[2])));
const z = new Uint8Array(readFileSync(process.argv[3]));
const x = w.x, sp0 = x.h_sp();
const used = (f) => { const lo = 2048, hi = sp0 - 1024; new Uint8Array(x.memory.buffer).fill(0xA5, lo, hi); f(); const m = new Uint8Array(x.memory.buffer); let i = lo; while (i < hi && m[i] === 0xA5) i++; return sp0 - i; };
const s = used(() => stream(w, z, 65536, 1));
const d = used(() => { x.h_task(2); const p = x.h_in(z.length + 4); const m = new Uint8Array(x.memory.buffer); m.set([0, 0, 0, 64], p); m.set(z, p + 4); x.h_call(1, p, z.length + 4); x.h_res_release(); x.h_free(p); x.h_end_trap(2); });
console.log(JSON.stringify({ wasm: process.argv[2].split('/').pop(), streamStackKB: +(s / 1024).toFixed(1), decodeStackKB: +(d / 1024).toFixed(1) }));
