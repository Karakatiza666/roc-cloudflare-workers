// PLAN.md 2d: TRAP_CLEAN is set only while a task runs, and handle clears it.
// node bench/trapclean-test.mjs bench/out/app.wasm
// `task_abort` gives -1 when the last trap was not clean, else the bytes it freed.
import { readFileSync } from 'node:fs';
import { makeWait } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const enc = new TextEncoder();
let failed = false;
const row = (name, got, want) => {
  const pass = got === want;
  if (!pass) failed = true;
  console.log(`${name}: task_abort ${got} (want ${want}): ${pass ? 'ok' : 'FAIL'}`);
};
const io = async (kind, a, b) => (kind === 1 ? 'f:1' : 'd:1');
const instance = () => {
  const cell = { x: null };
  const ex = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io)) } }).exports;
  cell.x = ex;
  ex.set_free_mark(crypto.getRandomValues(new Uint32Array(1))[0] | 1);
  ex.init(1);
  return ex;
};
let lastId = 0;
const start = (ex, req) => {
  const bytes = enc.encode(req);
  const p = ex.js_alloc(bytes.length);
  new Uint8Array(ex.memory.buffer).set(bytes, p);
  return WebAssembly.promising(ex.handle)(p, bytes.length, ++lastId);
};

// 1. A trap in a host call from JS (no task runs) is not clean: `alloc_bench` fails its
//    allocation. Before 2d, the trap set the flag, and `task_abort` freed nothing and said clean.
{
  const ex = instance();
  ex.fail_next_alloc();
  let trapped = false;
  try { ex.alloc_bench(1, 1, 16); } catch { trapped = true; }
  if (!trapped) { failed = true; console.log('FAIL: no trap'); }
  row('host call from JS traps', ex.task_abort(lastId), -1);
}
// 2. A flag left by a clean trap that nobody aborted must not make the trap of a later task clean.
//    Task 1 crashes (clean). Task 2 ends well, and must start with the flag cleared.
{
  const ex = instance();
  let trapped = false;
  await start(ex, '9001 1 5 10').catch(() => { trapped = true; });
  if (!trapped) { failed = true; console.log('FAIL: no trap'); }
  await start(ex, '9002 0 5 10');
  row('flag left by an earlier trap', ex.task_abort(lastId), -1);
}
// 3. A crash in a task is clean (the rule still holds while a task runs).
{
  const ex = instance();
  await start(ex, '9003 1 5 10').catch(() => {});
  const n = ex.task_abort(lastId);
  row('crash in a task is clean', n !== -1, true);
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
