// workerd: speed of the stream of each probe wasm. Usage: WORKERD=<bin> node run-workerd.mjs <reps> <file.zst> <variant>...
// A variant is a name of out/<name>.wasm. Env: CHUNK (default 65536), PORT (default 8197).
// One warm-up request, then `reps` timed requests for each variant (wall time of the client: workerd stops its
// clocks while a Worker runs). An empty request (`chunk` = input size, a tiny file) is not subtracted: the request
// costs about 1 ms on localhost.
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, copyFileSync, readFileSync } from 'node:fs';
import { join, basename } from 'node:path';
const here = new URL('.', import.meta.url).pathname;
const [repsArg, file, ...vs] = process.argv.slice(2);
const reps = Number(repsArg), CHUNK = Number(process.env.CHUNK ?? 65536), PORT = Number(process.env.PORT ?? 8197);
const W = join(here, 'out', 'workerd'); mkdirSync(W, { recursive: true });
copyFileSync(join(here, 'core.mjs'), join(W, 'core.mjs'));
copyFileSync(file, join(W, 'input.zst'));
const names = vs.map((v, i) => [v, `w${i}`]);
writeFileSync(join(W, 'worker.mjs'), readFileSync(join(here, 'worker.mjs'), 'utf8').replace('import input', names.map(([v, n]) => `import ${n} from '${v}.wasm';\n`).join('') + 'import input').replace('WASMS', names.map(([v, n]) => `'${v}': ${n}`).join(', ')));
for (const v of vs) copyFileSync(join(here, 'out', `${v}.wasm`), join(W, `${v}.wasm`));
writeFileSync(join(W, 'config.capnp'), `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [ (name = "main", worker = (modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"), (name = "core.mjs", esModule = embed "core.mjs"),
    (name = "input.zst", data = embed "input.zst"),
${vs.map((v) => `    (name = "${v}.wasm", wasm = embed "${v}.wasm"),`).join('\n')}
  ], compatibilityDate = "2026-10-01")) ],
  sockets = [ (name = "http", address = "127.0.0.1:${PORT}", http = (), service = "main") ],
);
`);
const p = spawn(process.env.WORKERD, ['serve', join(W, 'config.capnp')], { stdio: ['ignore', 'inherit', 'inherit'] });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
try {
  for (let i = 0; i < 100; i++) { try { await fetch(`http://127.0.0.1:${PORT}/`); break; } catch { await sleep(100); } }
  for (const v of vs) {
    const url = `http://127.0.0.1:${PORT}/run?v=${v}&chunk=${CHUNK}`;
    const warm = await (await fetch(url)).json();
    const ts = [];
    for (let r = 0; r < reps; r++) { const t0 = performance.now(); const j = await (await fetch(url)).json(); ts.push(performance.now() - t0); if (j.out !== warm.out || j.status) throw new Error(JSON.stringify(j)); }
    ts.sort((a, b) => a - b);
    const ms = ts[ts.length >> 1];
    console.log(JSON.stringify({ runtime: 'workerd', wasm: v, file: basename(file).slice(0, 12), chunk: CHUNK, out: warm.out, status: warm.status, code: warm.code, wallMs: +ms.toFixed(1), MBps: +(warm.out / 1e6 / (ms / 1000)).toFixed(0), peakLiveMB: +(warm.peakLive / 2 ** 20).toFixed(2), wasmMemMB: warm.wasmMem / 2 ** 20 }));
  }
} finally { p.kill(); }
