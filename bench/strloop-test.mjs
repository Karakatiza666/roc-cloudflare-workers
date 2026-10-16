// String loop test (bug B5, PLAN.md 6e): node bench/strloop-test.mjs bench/out/app_strloop.wasm [steps...]
// Each step count runs on a new shared instance. Pass: the body is correct and wasm
// memory stays under 6 MB. Default steps: 5000 10000 80000. Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const LIMIT = 6 * 2 ** 20;
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const steps = process.argv.slice(3).map(Number);
let failed = false;
for (const n of steps.length ? steps : [5000, 10000, 80000]) {
  const r = makeRunner(module, async () => 'x');
  const res = await r.run(String(n));
  let want = '';
  for (let i = 0; i < n; i++) want += `,${i}`;
  const mem = r.x.memory.buffer.byteLength;
  const ok = res.body === want && mem < LIMIT && r.x.live_bytes() === 0;
  if (!ok) failed = true;
  console.log(`${n} steps: ${res.body !== undefined ? `body ${res.body.length} B${res.body === want ? '' : ' WRONG'}` : res.trap.slice(0, 60)}, memory ${(mem / 2 ** 20).toFixed(1)} MB, live ${r.x.live_bytes()}: ${ok ? 'ok' : 'FAIL'}`);
}
process.exit(failed ? 1 : 0);
