// PLAN.md 12a-stack: test of the stack copy. node bench/stack-test.mjs bench/out/app_stack.wasm [rounds=5]
// Each round: 64 tasks at random depths from 10 to 4,000 frames (bench/app_stack.roc), each with a
// canary record in each frame, and 3 waits at the bottom. The io of each wait ends after a random
// delay, so the tasks wait and resume in random order. Each frame checks its canary and the canary
// of its parent after the waits. Expect "bad=0" from each task, and live bytes 0 at the end.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const rounds = Number(process.argv[3] ?? 5);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const r = makeRunner(module, 'b', async () => {
  await sleep(Math.random() * 10);
  return 'x';
});
if (r.stats.fallback) {
  console.log('FAIL: the module is not stack-first');
  process.exit(1);
}
let bad = 0, tasks = 0, minD = Infinity, maxD = 0;
for (let k = 0; k < rounds; k++) {
  const depths = Array.from({ length: 64 }, (_, i) => (i === 0 ? 10 : i === 1 ? 4000 : 10 + Math.floor(Math.random() * 3991)));
  const res = await Promise.all(depths.map((d, i) => r.run(`${1000 * k + i + 1} ${d} 3`)));
  res.forEach((x, i) => {
    tasks++;
    minD = Math.min(minD, depths[i]);
    maxD = Math.max(maxD, depths[i]);
    if (x.body !== 'bad=0') {
      bad++;
      if (bad < 5) console.log('BAD', `depth ${depths[i]}:`, x.body ?? x.trap);
    }
  });
}
const x = r.x;
console.log({ tasks, bad, depths: `${minD} to ${maxD}`, savedMaxBytes: x.task_saved_max(), waits: x.task_waits(), live: x.live_bytes(), replaced: r.stats.retired });
const ok = bad === 0 && x.live_bytes() === 0 && r.stats.retired === 0;
console.log(ok ? 'PASS' : 'FAIL');
process.exit(ok ? 0 : 1);
