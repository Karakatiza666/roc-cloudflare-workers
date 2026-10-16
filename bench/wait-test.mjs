// PLAN.md 2b: the wait import (`js_await` of js/bridge.js, API.md 4.1) always gives a status and never rejects.
// node bench/wait-test.mjs bench/out/app.wasm
// Part 1: `js_await` alone, with fake exports. Part 2: the real instance, with a JS error in the code after the op
// (in `js_alloc`), and with an op that throws and one that rejects.
// A throw into the waiting task would skip `waitEnd`: its stack copy and heap stay.
// Until 8a this was the test of `makeWait` (the import `js_wait`). Statuses since 8a: 0 a value, 1 a throw or a
// rejection (was 0: no result), 3 a bad program, 4 no block (also a throw in `js_alloc`: was 0).
import { readFileSync } from 'node:fs';
import { check, eventBlock, outcomeBody } from './core.js';
import { makeBridge } from '../js/bridge.js';
import { makePins } from '../js/helpers.js';
import { toJs } from '../js/values.js';

let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const shimOf = (ops) => ({ ops, pins: makePins(), log: () => {} });
// The program `[["call", ["root", "ops"], "io", []]]` as CBOR.
const PROGRAM = toJs([['call', ['root', 'ops'], 'io', []]]).slice();

// Part 1.
const memory = new WebAssembly.Memory({ initial: 1 });
new Uint8Array(memory.buffer).set(PROGRAM, 64);
const freed = [];
const call = async (io, js_alloc, args = [64, PROGRAM.length, 512]) => {
  const { js_await } = makeBridge({ x: { memory, js_alloc, res_free: (p) => freed.push(p) } }, null, shimOf({ io }));
  try {
    return { status: await js_await(0, ...args) };
  } catch (e) {
    return { rejected: String(e) };
  }
};
const alloc = () => 1024;
const cases = [
  ['the op gives a value', () => Promise.resolve('hi'), alloc, 0],
  ['the op throws', () => { throw new Error('sync'); }, alloc, 1],
  ['the op rejects', () => Promise.reject(new Error('async')), alloc, 1],
  ['the op gives a BigInt above 64 bits (J1: the encode throws)', () => 2n ** 70n, alloc, 1],
  ['js_alloc throws', () => 'hi', () => { throw new Error('trap'); }, 4],
  ['js_alloc gives 0', () => 'hi', () => 0, 4],
];
for (const [name, io, js_alloc, want] of cases) {
  const r = await call(io, js_alloc);
  const pass = r.status === want;
  if (!pass) fail(name, r);
  console.log(`${name}: ${JSON.stringify(r)} (want status ${want}): ${pass ? 'ok' : 'FAIL'}`);
}
{
  // An argument block that is not CBOR: a bad program (status 3), no rejection.
  new Uint8Array(memory.buffer).set([0xff, 0x00], 32);
  const r = await call(() => 'hi', alloc, [32, 2, 512]);
  if (r.status !== 3) fail('a bad argument block', r);
  console.log(`a bad argument block: ${JSON.stringify(r)} (want status 3)`);
}
// A throw after the block was made: the block is freed, because `out` does not hold it.
freed.length = 0;
{
  const r = await call(() => 'hi', alloc, [64, PROGRAM.length, 1 << 30]);
  if (r.rejected) fail('rejected', r);
  if (freed.join() !== '1024') fail('block not freed after a throw', freed);
}

// Part 2.
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const victims = { sync: '7001', reject: '7002', alloc: '7003' };
let throwInAlloc = false;
const io = async (kind, a, b) => {
  await new Promise((r) => setTimeout(r, 2));
  const id = kind === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
  if (kind === 1 && id === victims.sync) throw new Error('sync');
  if (kind === 1 && id === victims.reject) return Promise.reject(new Error('async'));
  if (kind === 1 && id === victims.alloc) throwInAlloc = true;
  return (kind === 1 ? 'f:' : 'd:') + id;
};
// The ops of bench/app.roc (bench/ops.js).
const ops = { fetch: (m, url) => io(1, m, url), db: (q) => io(2, q, '') };
const cell = { x: null };
const bridge = makeBridge(cell, null, shimOf(ops));
const inst = new WebAssembly.Instance(module, { env: { js_await: new WebAssembly.Suspending(bridge.js_await), js_call: bridge.js_call, js_grow: () => 1 } });
const ex = inst.exports;
ex.set_free_mark(crypto.getRandomValues(new Uint32Array(1))[0] | 1);
ex.init(1);
// The wait code gets a wrapper whose js_alloc throws once, when io asked for it.
cell.x = {
  memory: ex.memory,
  res_free: ex.res_free,
  js_alloc: (n) => {
    if (throwInAlloc) { throwInAlloc = false; throw new Error('js error after io'); }
    return ex.js_alloc(n);
  },
};
const handle = WebAssembly.promising(ex.handle);
let lastId = 0;
const run = async (req) => {
  // PLAN.md 8b: the request text is the body of a `Fetch` event, and the body of the outcome is the answer.
  const [p, len] = eventBlock(ex, req);
  const id = ++lastId;
  let blk;
  try {
    blk = await handle(p, len, id);
  } catch (e) {
    // A trap: the runner frees the pages of the task (task_abort).
    ex.task_abort(id, 0);
    return { trap: String(e), cause: ex.trap_cause() };
  }
  return { body: outcomeBody(ex, blk) };
};
const ids = [...Object.values(victims), ...Array.from({ length: 20 }, (_, i) => String(7100 + i))];
const res = await Promise.allSettled(ids.map((id) => run(`${id} 0 5 10`)));
let bad = 0, rejected = 0;
res.forEach((r, i) => {
  const id = ids[i];
  if (r.status !== 'fulfilled') { rejected++; return; }
  // A throw in js_alloc is status 4: a clean OOM trap of that task (cause 2).
  if (id === victims.alloc) {
    if (r.value.cause !== 2) { bad++; console.log('alloc victim:', r.value); }
    return;
  }
  const victim = Object.values(victims).includes(id);
  // A victim wait has no result: the app gets an empty body and still answers.
  if (r.value.body === undefined || (victim ? !r.value.body.endsWith(`fetch= db=d:${id}`) : !check(id, r.value.body, 5))) bad++;
});
const live = ex.live_bytes(), waiting = ex.task_waiting(), miss = ex.dealloc_miss();
console.log({ rejected, bad, live, waiting, miss });
if (rejected !== 0 || bad !== 0) fail('a task was lost or has a wrong body');
if (live !== 0 || waiting !== 0 || miss !== 0) fail('live bytes, waiting tasks or dealloc_miss not 0');
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
