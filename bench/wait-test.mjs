// PLAN.md 2b: makeWait always gives a status and never rejects.
// node bench/wait-test.mjs bench/out/app.wasm
// Part 1: makeWait alone, with fake exports. Part 2: the real instance, with a JS error
// in the code after io (in `js_alloc`), and with io that throws and rejects.
// A throw into the waiting task would skip `waitEnd`: its stack copy and heap stay.
import { readFileSync } from 'node:fs';
import { makeWait, check } from './core.js';
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };

// Part 1.
const memory = new WebAssembly.Memory({ initial: 1 });
const freed = [];
const call = async (io, js_alloc) => {
  const wait = makeWait({ x: { memory, js_alloc, res_free: (p) => freed.push(p) } }, io);
  try {
    return { status: await wait(1, 0, 0, 0, 0, 0, 0, 0, 512) };
  } catch (e) {
    return { rejected: String(e) };
  }
};
const alloc = () => 1024;
const cases = [
  ['io ok', () => Promise.resolve('hi'), alloc, 200],
  ['io throws', () => { throw new Error('sync'); }, alloc, 0],
  ['io rejects', () => Promise.reject(new Error('async')), alloc, 0],
  ['io gives a Symbol (encode throws)', () => Symbol('x'), alloc, 0],
  ['js_alloc throws', () => 'hi', () => { throw new Error('trap'); }, 0],
  ['js_alloc gives 0', () => 'hi', () => 0, 4],
];
for (const [name, io, js_alloc, want] of cases) {
  const r = await call(io, js_alloc);
  const pass = r.status === want;
  if (!pass) fail(name, r);
  console.log(`${name}: ${JSON.stringify(r)} (want status ${want}): ${pass ? 'ok' : 'FAIL'}`);
}
// A throw after the block was made: the block is freed, because `out` does not hold it.
freed.length = 0;
const wait = makeWait({ x: { memory, js_alloc: alloc, res_free: (p) => freed.push(p) } }, () => 'hi');
await wait(1, 0, 0, 0, 0, 0, 0, 0, 1 << 30).catch((e) => fail('rejected', e));
if (freed.join() !== '1024') fail('block not freed after a throw', freed);

// Part 2.
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const dec = new TextDecoder(), enc = new TextEncoder();
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
const cell = { x: null };
const inst = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io)) } });
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
  const bytes = enc.encode(req);
  const p = ex.js_alloc(bytes.length);
  new Uint8Array(ex.memory.buffer).set(bytes, p);
  const blk = await handle(p, bytes.length, ++lastId);
  const len = new DataView(ex.memory.buffer).getUint32(blk, true);
  const s = dec.decode(new Uint8Array(ex.memory.buffer, blk + 4, len));
  ex.res_free(blk);
  return s;
};
const ids = [...Object.values(victims), ...Array.from({ length: 20 }, (_, i) => String(7100 + i))];
const res = await Promise.allSettled(ids.map((id) => run(`${id} 0 5 10`)));
let bad = 0, rejected = 0;
res.forEach((r, i) => {
  const id = ids[i];
  if (r.status !== 'fulfilled') { rejected++; return; }
  const victim = Object.values(victims).includes(id);
  // A victim wait has no result: the app gets an empty body and still answers.
  if (victim ? !r.value.endsWith(`fetch= db=d:${id}`) : !check(id, r.value, 5)) bad++;
});
const live = ex.live_bytes(), waiting = ex.task_waiting(), miss = ex.dealloc_miss();
console.log({ rejected, bad, live, waiting, miss });
if (rejected !== 0 || bad !== 0) fail('a task was lost or has a wrong body');
if (live !== 0 || waiting !== 0 || miss !== 0) fail('live bytes, waiting tasks or dealloc_miss not 0');
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
