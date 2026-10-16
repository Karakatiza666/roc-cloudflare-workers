// PLAN.md 6d and 2a: a failed allocation is a clean OOM trap for one task.
// node bench/oom-test.mjs bench/out/app.wasm
// 6d: `fail_next_alloc` before the next `roc_alloc` of a task: it traps clean, `task_abort`
//     frees its pages, the other tasks are correct.
// 2a: `fail_next_alloc` before a `js_alloc` for a wait result: JS gives status 4, and the
//     host makes the same clean trap.
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Six digits: "select <id>" has 13 bytes, so Roc must allocate it after the first wait.
const ID = (i) => String(100000 + i);
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
// Variant b only: the io of variant a has no way to reach the instance of its request.
for (const v of ['b']) {
  // case -> id of the victim. 'roc': the next allocation is Roc's. 'js': the next one is js_alloc.
  const victim = { roc: ID(3), js: ID(11) };
  let r;
  const io = async (kind, a, b) => {
    if (kind === 1) {
      await sleep(3);
      const id = new URL(b).searchParams.get('id');
      // The empty body makes no js_alloc, so the next allocation is the `roc_alloc` of the task.
      if (id === victim.roc) { r.x.fail_next_alloc(); return ''; }
      return 'f:' + id;
    }
    await sleep(1);
    const id = a.split(' ')[1];
    if (id === victim.js) r.x.fail_next_alloc();
    return 'd:' + id;
  };
  r = makeRunner(module, v, io);
  let bad = 0, traps = 0;
  const trapped = [];
  for (let round = 0; round < 2; round++) {
    const ids = Array.from({ length: 30 }, (_, i) => ID(round * 30 + i));
    const res = await Promise.all(ids.map((id) => r.run(`${id} 0 5 10`)));
    res.forEach((x, i) => {
      if (x.trap) { traps++; trapped.push(ids[i]); } else if (!check(ids[i], x.body, 5)) bad++;
    });
  }
  const x = r.x;
  const live = x.live_bytes(), miss = x.dealloc_miss();
  const want = [victim.roc, victim.js].sort().join();
  console.log(v, { bad, traps, trapped: trapped.sort().join(), freed: r.stats.freed, walkFailed: r.stats.walkFailed, retired: r.stats.retired, live, miss });
  if (bad !== 0) fail(v, 'bad bodies');
  if (trapped.sort().join() !== want) fail(v, 'only the two victims must trap');
  if (r.stats.walkFailed !== 0 || r.stats.retired !== 0) fail(v, 'a trap was not clean');
  if (live !== 0 || miss !== 0) fail(v, 'live bytes or dealloc_miss not 0');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
