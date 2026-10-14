import { readFileSync } from 'node:fs';
import { makeRunner } from '../harness/bench/core.js';
const wasm = (name) => readFileSync(new URL(`../out/${name}.wasm`, import.meta.url));
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const [base, steps, items, ss = 3] = process.argv.slice(2).map(Number);
// v5 page sizes. node tune5.mjs <large base units> <large steps> <items> [small steps]
const r = makeRunner(new WebAssembly.Module(wasm('app_v5')), 'b', io);
r.x.set_large_min_run(base); r.x.set_large_steps(steps); r.x.set_small_steps(ss); r.x.set_sum(1);
let id = 1;
for (let b = 0; b < 50; b++) await Promise.all(Array.from({ length: 64 }, () => r.run(`${id++} 0 50 ${items}`)));
const w0 = r.x.task_waits(), s0 = r.x.sum_bytes();
for (let b = 0; b < 10; b++) await Promise.all(Array.from({ length: 64 }, () => r.run(`${id++} 0 50 ${items}`)));
console.log(`small x2^${ss}, large ${base * 4} KB x2^${steps}, ${items} items: mem MB`, (r.x.memory.buffer.byteLength / 2 ** 20).toFixed(1), 'pages peak MB', (r.x.heap_peak() / 2 ** 20).toFixed(1), 'live peak MB', (r.x.live_peak() / 2 ** 20).toFixed(1), 'sum KB/wait', ((r.x.sum_bytes() - s0) / (r.x.task_waits() - w0) / 1024).toFixed(0));
