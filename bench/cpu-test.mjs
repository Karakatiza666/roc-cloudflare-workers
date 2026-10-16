// PLAN.md problem 5 (CPU limit flags of workerd), steps 5a to 5c.
// node bench/cpu-test.mjs [bench/out]   (needs app.wasm, app_deep.wasm, app_strloop.wasm, app_wait.wasm)
// 5a: both globals are exported as globals (the form of the workerd shim: `Global.value` is an
//     address), 4-aligned and in memory, and the u32 there starts as 0xFFFF.
// 5b: the CPU signal (24) in memory: a clean trap with the cause "cpu" (status 503), live bytes 0,
//     the instance stays. A: at an allocation (no wait). B: at a wait (app_wait: no allocation by the app at all).
//     C: written during a request, many tasks at once.
// 5c: the terminated flag (1) at the start of a request: the instance is replaced. A kill leaves
//     stale state (here: a stack pointer that is wrapped), so a request on the old instance traps.
import { readFileSync } from 'node:fs';
import { makeRunner, check, readFlag, SIGXCPU, TERMINATED } from './core.js';
const dir = process.argv[2] ?? 'bench/out';
const load = (f) => new WebAssembly.Module(readFileSync(`${dir}/${f}`));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const fail = (...m) => { failed = true; console.log('FAIL', ...m); };
const io = async (kind, a, b) => {
  await sleep(kind === 1 ? 3 : 1);
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
// What the runtime does: write the u32 at the address of the global.
const writeFlag = (x, name, v) => new DataView(x.memory.buffer).setUint32(x[name].value, v, true);
const strloop = (n) => Array.from({ length: n }, (_, i) => `,${i}`).join('');

// 5a
for (const f of ['app.wasm', 'app_deep.wasm', 'app_strloop.wasm', 'app_wait.wasm']) {
  const m = load(f);
  const ex = WebAssembly.Module.exports(m);
  const x = new WebAssembly.Instance(m, { env: { js_wait: () => 0 } }).exports;
  const addr = [];
  for (const name of ['__instance_signal', '__instance_terminated']) {
    if (ex.find((e) => e.name === name)?.kind !== 'global') { fail(`5a ${f}: ${name} is not exported as a global`); continue; }
    const v = x[name].value;
    const ok = x[name] instanceof WebAssembly.Global && Number.isInteger(v) && v % 4 === 0 && v + 4 <= x.memory.buffer.byteLength;
    if (!ok) fail(`5a ${f}: ${name} is not the address of a u32 in memory (${v})`);
    else if (readFlag(x, name) !== 0xffff) fail(`5a ${f}: ${name} starts as ${readFlag(x, name)}, want 65535`);
    addr.push(v);
  }
  if (addr.length === 2 && addr[0] === addr[1]) fail(`5a ${f}: the two globals have one address`);
  console.log('5a', f, 'addresses', addr);
}

// 5b A: an allocation after the signal. app_strloop has no wait: only the allocation check can trap.
{
  const r = makeRunner(load('app_strloop.wasm'), 'b', io);
  const x = r.x;
  writeFlag(x, '__instance_signal', SIGXCPU);
  const res = await r.run('100');
  console.log('5b A', res.body !== undefined ? 'body' : res.trap, res.status, res.cause);
  if (res.body !== undefined) fail('5b A: the request ran to its end with the signal set');
  else if (res.status !== 503 || res.cause !== 'cpu') fail(`5b A: want 503 cpu, got ${res.status} ${res.cause} (${res.trap})`);
  if (x.live_bytes() !== 0) fail(`5b A: live bytes ${x.live_bytes()}`);
  if (r.stats.retired || r.stats.walkFailed || r.x !== x) fail('5b A: the instance did not stay');
  writeFlag(x, '__instance_signal', 0); // the runtime clears it
  const next = await r.run('60');
  if (next.body !== strloop(60)) fail(`5b A: next request gave ${next.body ?? next.trap}`);
}

// 5b B: a wait after the signal. app_wait allocates nothing in the app: only the check in waitBegin can trap.
{
  const r = makeRunner(load('app_wait.wasm'), 'b', io);
  const x = r.x;
  const first = await r.run('x');
  if (first.body !== 'ok') fail(`5b B: control run gave ${first.body ?? first.trap}`);
  writeFlag(x, '__instance_signal', SIGXCPU);
  const res = await r.run('x');
  console.log('5b B', res.body !== undefined ? 'body' : res.trap, res.status, res.cause);
  if (res.body !== undefined) fail('5b B: the request ran to its end with the signal set');
  else if (res.status !== 503 || res.cause !== 'cpu') fail(`5b B: want 503 cpu, got ${res.status} ${res.cause} (${res.trap})`);
  if (x.live_bytes() !== 0) fail(`5b B: live bytes ${x.live_bytes()}`);
  if (r.stats.retired || r.stats.walkFailed || r.x !== x) fail('5b B: the instance did not stay');
  writeFlag(x, '__instance_signal', 0);
  const next = await r.run('x');
  if (next.body !== 'ok') fail(`5b B: next request gave ${next.body ?? next.trap}`);
}

// 5b C: the signal comes during a request (in the io of the victim), 30 tasks wait at that time.
// The signal is for the whole instance: the tasks that resume while it is set trap clean too.
{
  const m = load('app.wasm');
  let r = null;
  const sigIo = async (kind, a, b) => {
    if (kind === 1 && b.includes('id=9000')) {
      writeFlag(r.x, '__instance_signal', SIGXCPU);
      await sleep(3);
      return 'f:9000';
    }
    return io(kind, a, b);
  };
  r = makeRunner(m, 'b', sigIo);
  const x = r.x;
  const ids = Array.from({ length: 30 }, (_, i) => String(100 + i));
  const others = ids.map((id) => r.run(`${id} 0 5 20`).then((res) => ({ id, res })));
  const victim = await r.run('9000 0 5 20');
  writeFlag(x, '__instance_signal', 0);
  let bad = 0, cpu = 0, ok = 0, other = 0;
  for (const { id, res } of await Promise.all(others)) {
    if (res.body !== undefined) { if (check(id, res.body, 5)) ok++; else bad++; }
    else if (res.cause === 'cpu' && res.status === 503) cpu++;
    else other++;
  }
  console.log('5b C', { victim: victim.body !== undefined ? 'body' : victim.cause, ok, cpu, bad, other, retired: r.stats.retired, walkFailed: r.stats.walkFailed, live: x.live_bytes() });
  if (victim.body !== undefined) fail('5b C: the victim ran to its end');
  else if (victim.cause !== 'cpu' || victim.status !== 503) fail(`5b C: victim gave ${victim.status} ${victim.cause} (${victim.trap})`);
  if (bad || other) fail(`5b C: ${bad} bad bodies, ${other} traps that are not cpu`);
  if (r.stats.retired || r.stats.walkFailed || r.x !== x) fail('5b C: the instance did not stay');
  if (x.live_bytes() !== 0 || x.task_waiting() !== 0 || r.tasks.size !== 0) fail('5b C: live bytes, waiting tasks or table not 0');
  const after = await Promise.all(ids.map((id) => r.run(`${id} 0 5 20`).then((res) => check(id, res.body ?? '', 5))));
  if (after.some((v) => !v)) fail('5b C: a request after the signal was cleared is wrong');
}

// 5c: a kill leaves a stale state. `fault_next_wait(3)` traps a task with a wrapped stack pointer,
// and nobody calls task_abort. Then the runtime writes the flag.
{
  const r = makeRunner(load('app_deep.wasm'), 'b', io);
  const x0 = r.x;
  // Negative control: no flag, the instance stays.
  const a = await r.run('5');
  if (r.x !== x0 || r.stats.terminated || a.body === undefined) fail('5c: control run');
  // The kill: a task is stopped at a wait, and nothing cleans up.
  x0.fault_next_wait(3);
  const bytes = new TextEncoder().encode('7');
  const p = x0.js_alloc(bytes.length);
  new Uint8Array(x0.memory.buffer).set(bytes, p);
  let trapped = false;
  await WebAssembly.promising(x0.handle)(p, bytes.length, 4_000_000_000).catch(() => { trapped = true; });
  if (!trapped) fail('5c: the forced trap did not happen');
  writeFlag(x0, '__instance_terminated', TERMINATED);
  let next;
  try {
    next = await r.run('5');
  } catch (e) {
    next = { trap: `threw ${e}` };
  }
  console.log('5c', { replaced: r.x !== x0, terminated: r.stats.terminated, retired: r.stats.retired, next: next.body ?? next.trap });
  if (next.body !== a.body) fail(`5c: next request gave ${next.body ?? next.trap}`);
  if (r.x === x0 || r.stats.terminated !== 1 || r.stats.retired !== 1) fail('5c: the instance was not replaced');
  const x1 = r.x;
  const again = await r.run('5');
  if (again.body !== a.body || r.x !== x1 || r.stats.retired !== 1) fail('5c: a later request replaced the instance again');
  if (readFlag(x1, '__instance_terminated') !== 0xffff) fail('5c: the new instance does not start with 0xFFFF');
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
