// Node check of the shared instance (no workerd): node bench/node-test.mjs bench/out/app.wasm
// Batch 1: 200 requests at once, 4 of them trap after their first wait.
// Batch 2: 200 more, no traps, on the same instance (a freed span still in use would show here).
// Exit 1 when a body is bad or live bytes are not 0 at the end.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  if (kind === 1) { await sleep(5); return 'f:' + new URL(b).searchParams.get('id'); }
  await sleep(1); return 'd:' + a.split(' ')[1];
};
let failed = false;
// No memory budget here: 200 requests at once.
const r = makeRunner(module, io, { isolateBytes: 2 ** 40 });
const one = await r.run('123 0');
console.log(one.body?.slice(0, 40), one.body?.slice(-60), check('123', one.body ?? ''));
let bad = 0, traps = 0;
for (const [base, withTraps] of [[1000, true], [2000, false]]) {
  const ids = Array.from({ length: 200 }, (_, i) => String(base + i));
  const res = await Promise.all(ids.map((id, i) => r.run(`${id} ${withTraps && i % 50 === 7 ? 1 : 0}`)));
  res.forEach((x, i) => { if (x.trap) traps++; else if (!check(ids[i], x.body)) { bad++; if (bad < 3) console.log('BAD', ids[i], x.body); } });
}
const x = r.x;
const live = x.live_bytes();
console.log({ bad, traps, freed: r.stats.freed, walkFailed: r.stats.walkFailed, mem: x.memory.buffer.byteLength, heap_used: x.heap_used(), live, saved_max: x.task_saved_max(), waiting: x.task_waiting(), canary: x.stack_canary_ok() });
if (bad !== 0 || traps !== 4 || live !== 0) { failed = true; console.log('FAIL'); }
process.exit(failed ? 1 : 0);
