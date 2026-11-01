// Node: speed of the zstd stream of a probe wasm. Usage: node run.mjs <wasm> <reps> <file.zst>...
// Env: CHUNK (input bytes of one push, default 65536), VERIFY=1 (SHA-256 of the output, compare with `zstd -dc | sha256sum`).
// For each file: one verify or warm run, then `reps` timed runs in the same instance. Prints one JSON line per file.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { basename } from 'node:path';
import { instantiate, stream } from './core.mjs';
const [wasm, repsArg, ...files] = process.argv.slice(2);
const CHUNK = Number(process.env.CHUNK ?? 65536);
const reps = Number(repsArg ?? 3);
const w = await instantiate(new WebAssembly.Module(readFileSync(wasm)));
let owner = 1;
for (const f of files) {
  const z = new Uint8Array(readFileSync(f));
  const sha = createHash('sha256');
  const first = stream(w, z, CHUNK, owner++, process.env.VERIFY ? (b) => sha.update(b) : undefined);
  if (first.status) { console.log(JSON.stringify({ wasm: basename(wasm), file: basename(f), error: first.code })); continue; }
  const cpu = [], wall = [];
  for (let r = 0; r < reps; r++) {
    const c0 = process.cpuUsage(), t0 = performance.now();
    const got = stream(w, z, CHUNK, owner++);
    const t = performance.now() - t0, c = process.cpuUsage(c0);
    if (got.status || got.out !== first.out) throw new Error('run differs: ' + JSON.stringify(got));
    cpu.push((c.user + c.system) / 1000); wall.push(t);
  }
  const med = (a) => [...a].sort((p, q) => p - q)[a.length >> 1];
  const ms = med(cpu);
  console.log(JSON.stringify({ wasm: basename(wasm), file: basename(f).slice(0, 12), chunk: CHUNK, packed: z.length, out: first.out,
    sha: process.env.VERIFY ? sha.digest('hex') : undefined, cpuMs: +ms.toFixed(1), wallMs: +med(wall).toFixed(1),
    MBps: +(first.out / 1e6 / (ms / 1000)).toFixed(0), peakLiveMB: +(first.peakLive / 2 ** 20).toFixed(2),
    maxPushKB: first.maxPush >> 10, wasmMemMB: w.x.memory.buffer.byteLength / 2 ** 20 }));
}
