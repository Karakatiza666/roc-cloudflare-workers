// PLAN.md 12d: the global check (`check_heap`).
// node bench/checkheap-test.mjs bench/out/app.wasm [bench/out/alloc_driver.wasm]
// A. App, variant b. For each kind of the test export `break_table` (one wild write into a table
//    entry of the shared memory, with no trap): 30 requests end (free runs, reserve pages), 10 wait
//    (task pages, wait records, adopted JS blocks). The check passes, then `break_table`, then the
//    runner check: it must fail, write one log line, and replace the instance (the 10 waiting tasks
//    get a 503, the next request is correct on the new instance).
// B. Allocator driver: the damage that the check finds. After a break, with no check, the next
//    allocations give blocks that overlap (as dfree.mjs). The check must find each break first.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner, check, CHECK_NAMES } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const failures = [];
const fail = (m) => { failures.push(m); console.log('FAIL', m); };
const tick = () => new Promise((r) => setTimeout(r, 0));

// Kinds of `break_table` (host/host.zig, hostlib/alloc.zig `breakTable`) and their arguments.
const KINDS = [
  [1, 'length of a free run'], [2, 'free bit of a small page in use'], [3, 'boundary tag of a free run'],
  [4, 'reserve page twice in the reserve'], [5, 'small page in use in the reserve'], [6, 'live count of a small page'],
  [7, 'free list of a small page points to a live block'], [8, 'back link of a task page list'],
  [9, 'page with room not in its list'], [10, 'slot of a large block'], [11, 'small page in use marked foreign'],
  [12, 'foreign unit below the pool'], [13, 'owner of a task slot'], [14, 'live byte count'],
  [15, 'count of used units'], [16, 'free mark'], [20, 'byte of .rodata', 64], [21, 'word of the canary', 7],
  [22, 'TASK_WAITING'], [23, 'index of a wait record'], [24, 'copy length of a wait record'], [25, 'log length'],
  [26, 'TASK_TOP'], [27, 'SUM_MODE'],
];

// A. ------------------------------------------------------------------------------------------
// Open each wait of `p` until it settles.
async function opened(p, gates) {
  let done = false;
  p.finally(() => (done = true));
  while (!done) {
    await tick();
    for (const [k, open] of gates) { gates.delete(k); open(); }
  }
  return p;
}

// io that waits until the test opens its gate `<kind>:<request id>`.
function gated(gates) {
  return (k, a, b) => {
    const id = k === 1 ? new URL(b).searchParams.get('id') : a.split(' ')[1];
    const v = k === 1 ? `f:${id}` : `d:${id}`;
    return new Promise((res) => gates.set(`${k}:${id}`, () => res(v)));
  };
}
async function open(gates, key) {
  for (let i = 0; i < 50 && !gates.has(key); i++) await tick();
  const g = gates.get(key);
  if (!g) throw new Error(`no wait ${key}`);
  gates.delete(key);
  g();
  for (let i = 0; i < 3; i++) await tick();
}

async function partA(kind, name, arg = 0) {
  const gates = new Map();
  const lines = [];
  const r = makeRunner(module, 'b', gated(gates), { heapCheckEvery: 0, heapCheckWhenIdle: false, log: (t) => lines.push(t) });
  const x0 = r.x;
  const runs = [];
  // Every 5th request makes 400 items (large blocks).
  for (let i = 0; i < 40; i++) runs.push(r.run(`${5000 + i} 0 6 ${i % 5 === 0 ? 400 : 20}`));
  // 30 tasks end: open their two waits. 10 stay at their first wait.
  for (let i = 0; i < 30; i++) {
    await open(gates, `1:${5000 + i}`);
    await open(gates, `2:${5000 + i}`);
  }
  const control = x0.check_heap();
  if (control !== 0) { fail(`A ${kind} ${name}: the check fails before the break (${control})`); return; }
  if (x0.task_waiting() !== 10) { fail(`A ${kind}: ${x0.task_waiting()} tasks wait, want 10`); return; }
  const hit = x0.break_table(kind, arg);
  if (hit !== 1) { fail(`A ${kind} ${name}: no target for the break: the test proves nothing`); return; }
  const code = x0.check_heap();
  const stays = r.checkHeap('test');
  for (const [k, g] of gates) { gates.delete(k); g(); }
  const res = await Promise.all(runs);
  const cancelled = res.filter((v) => v.cancelled === 'heap').length;
  const next = await opened(r.run('7 0 3 5'), gates);
  const row = { kind, name, code, found: CHECK_NAMES[code] ?? '-', replaced: r.x !== x0, cancelled, logLines: lines.length, next: check('7', next.body ?? '', 3) };
  console.log('A', JSON.stringify(row));
  if (code === 0 || stays) fail(`A ${kind} ${name}: the check did not find it`);
  if (r.x === x0 || r.stats.retired !== 1 || r.stats.heapFails !== 1) fail(`A ${kind} ${name}: the instance was not replaced`);
  if (cancelled !== 10) fail(`A ${kind} ${name}: ${cancelled} waiting tasks got a 503, want 10`);
  if (lines.length !== 1 || !/heap check failed/.test(lines[0])) fail(`A ${kind} ${name}: log lines ${JSON.stringify(lines)}`);
  if (!row.next) fail(`A ${kind} ${name}: the next request is wrong: ${next.body ?? next.trap}`);
}
for (const [kind, name, arg] of KINDS) await partA(kind, name, arg);

// B. ------------------------------------------------------------------------------------------
const drv = new WebAssembly.Module(readFileSync(process.argv[3] ?? 'bench/out/alloc_driver.wasm'));
const AL = 1 | (4 << 8); // alloc, alignment 4
let nextId = 1;
function driver() {
  const x = new WebAssembly.Instance(drv, {}).exports;
  const live = new Map(); // id -> [owner, length]
  const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
  const alloc = (owner, len) => { const id = nextId++; run([[AL, owner, id, len]]); live.set(id, [owner, len]); return id; };
  const free = (owner, id) => { run([[2, owner, id, 0]]); live.delete(id); };
  const end = (owner) => { run([[4, owner, 0, 0]]); for (const [id, [o]] of live) if (o === owner) live.delete(id); };
  // Live blocks that share a byte.
  const overlaps = () => {
    const b = [...live].map(([id, [, len]]) => [x.ptr_of(id), len]).sort((p, q) => p[0] - q[0]);
    let n = 0;
    for (let i = 0; i + 1 < b.length; i++) if (b[i][0] + b[i][1] > b[i + 1][0]) n++;
    return n;
  };
  return { x, run, alloc, free, end, overlaps };
}
// Kinds whose damage gives blocks that overlap at the next allocations.
const OVERLAP = [[1, 'length of a free run'], [2, 'free bit of a small page in use'], [4, 'reserve page twice'], [5, 'small page in use in the reserve'], [7, 'free list points to a live block']];
for (const [kind, name] of OVERLAP) {
  nextId = 1;
  const d = driver();
  // Task 7 keeps blocks of 24 B, 100 B, 3,000 B and 9,000 B. Task 8 takes pages and ends: free runs
  // and reserve pages. A free of every other 3,000 B block of task 7 leaves runs of one unit.
  const keep = [];
  for (let i = 0; i < 40; i++) for (const len of [24, 100, 3000, 9000]) keep.push([d.alloc(7, len), len]);
  for (let i = 0; i < 300; i++) d.alloc(8, [24, 100, 2048, 5000][i % 4]);
  d.end(8);
  keep.filter(([, len], i) => len === 3000 && i % 8 === 2).forEach(([id]) => d.free(7, id));
  const before = d.x.check_tables();
  d.run([[13, 0, kind, kind === 7 ? 7 : 0]]);
  const code = d.x.check_tables();
  // With no check: more blocks of tasks 7 and 9, until the reserve is used up and memory grows.
  for (let i = 0; i < 400; i++) d.alloc(i % 2 ? 9 : 7, [24, 100, 3000, 2048][i % 4]);
  const ov = d.overlaps();
  console.log('B', JSON.stringify({ kind, name, before, code, found: CHECK_NAMES[code] ?? '-', overlapsWithNoCheck: ov }));
  if (before !== 0) fail(`B ${kind}: the check fails before the break (${before})`);
  if (code === 0) fail(`B ${kind} ${name}: the check did not find it`);
  if (ov === 0) fail(`B ${kind} ${name}: no blocks overlap with no check: the test proves nothing`);
}

console.log(failures.length ? `FAIL (${failures.length})` : 'PASS');
process.exit(failures.length ? 1 : 0);
