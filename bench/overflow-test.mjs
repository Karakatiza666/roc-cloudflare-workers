// Stack overflow test: node bench/overflow-test.mjs <app_deep.wasm>
// Requests with deeper recursion until one traps, without and with an allocation per level.
// One shared instance on a stack-first module (a data-first module is refused: bench/layout-test.mjs):
//   - no request returns a body while the canary is broken, and each body is correct;
//   - the trap without allocation (out of bounds, wrapped stack pointer) is clean after 4-pre
//     (PLAN.md 4-pre, V1): the instance stays, live bytes are 0;
//   - the trap with allocation (canary) is clean too;
//   - a V8 RangeError (cold code, a fresh instance: the stack pointer is not wrapped) is clean too;
//   - the next request is correct;
//   - free mode (one list freed at the deepest frame, no other allocation): no request returns a
//     body while the canary is broken, and the first trap is clean. The free path checks the
//     canary first (`roc_dealloc`), so it traps before it changes a table;
//   - V2: a trap at normal stack depth (a forced out-of-bounds write, a forced unreachable) is
//     still unclean: an alarm (PLAN.md 12c). `task_abort` gives -1, the alarm counter of the host
//     goes up, the global check passes, and the instance stays (no replace).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const file = process.argv[2];
const module = new WebAssembly.Module(readFileSync(file));

// down() of bench/app_deep.roc. free: down_free(), the base record has a = salt + 5.
function ref(depth, alloc, free = false) {
  const m = (x) => x % 1000003n;
  // A loop, not recursion: the salt goes down the levels, the record comes back up.
  const down = (n, salt) => {
    for (let k = n; k > 0n; k--) salt = m(salt + k * 3n);
    let r = { a: free ? salt + 5n : salt, b: 1n, c: 2n, d: 1n, e: 3n, f: 4n, g: 5n, h: 6n, i: 7n, j: 8n, k: 9n, l: 10n, m: 11n, n: 12n, o: 13n, p: 14n };
    for (let k = 1n; k <= n; k++) {
      const extra = alloc ? 2n : 0n;
      r = { a: m(r.b + k + extra), b: m(r.c * 5n + k), c: m(r.a + r.d), d: r.d + 1n, e: m(r.f + r.e), f: m(r.g + k), g: m(r.h * 3n), h: m(r.i + 1n), i: m(r.j + r.a), j: m(r.k + 2n), k: m(r.l + k), l: m(r.m + 3n), m: m(r.n + r.b), n: m(r.o + 4n), o: m(r.p + k), p: m(r.a + r.c) };
    }
    return r;
  };
  const r = down(BigInt(depth), 17n);
  return `a=${r.a} d=${r.d} p=${r.p}`;
}

const failures = [];
const fail = (msg) => { failures.push(msg); console.log('FAIL', msg); };
// Cold code (the first request of a fresh module, before any other test runs): the engine
// stack ends first, with a RangeError (V1). Later requests run warm code and trap out of bounds.
{
  const c = makeRunner(module, async () => 'x');
  const res = await c.run('100000');
  console.log('cold depth 100000 trap:', String(res.trap).slice(0, 60), '| retired', c.stats.retired > 0, '| alarms', c.stats.alarms);
  if (res.body !== undefined) fail('cold 100000: no trap');
  else if (!/RangeError/.test(res.trap)) fail(`cold 100000: not a RangeError (${res.trap}): the test proves nothing`);
  if (c.stats.retired || c.stats.alarms) fail('cold 100000: a RangeError was not clean on a stack-first instance');
  if (c.x.live_bytes() !== 0) fail(`cold 100000: live bytes ${c.x.live_bytes()}`);
  const a = await c.run('5');
  if (a.body !== ref(5, false)) fail(`cold 100000: next request gave ${a.body ?? a.trap}`);
}
const r = makeRunner(module, async () => 'x');
console.log(file, 'shared instance');

const small = async (what) => {
  const a = await r.run('5');
  if (a.body !== ref(5, false)) fail(`${what}: next request gave ${a.body ?? a.trap}`);
  return a;
};

// 1b: a stack-first module shares one instance.
const s1 = await small('start');
const s2 = await small('start');
if (s1.x !== s2.x) fail('shared runner used two instances');

for (const alloc of [false, true]) {
  let trapped = false;
  for (const d of [1000, 2000, 3000, 4000, 4500, 5000, 5500, 6000, 7000, 8000, 10000, 15000, 20000]) {
    const retired = r.stats.retired + r.stats.alarms;
    const res = await r.run(`${d}${alloc ? ' alloc' : ''}`);
    const tag = `depth ${d}${alloc ? ' alloc' : ''}`;
    if (res.body !== undefined) {
      const canary = res.x.stack_canary_ok();
      console.log(tag, 'ok, canary', canary);
      if (canary !== 1) fail(`${tag}: a body with a broken canary`);
      if (res.body !== ref(d, alloc)) fail(`${tag}: wrong body ${res.body}`);
      continue;
    }
    trapped = true;
    const isRetired = r.stats.retired + r.stats.alarms > retired;
    console.log(tag, 'trap:', res.trap.slice(0, 60), '| retired or alarm', isRetired);
    // 4-pre: a stack-first overflow wrote nothing but the stack, so the trap is clean.
    if (isRetired) fail(`${tag}: an overflow trap was not clean on a stack-first instance`);
    if (res.x.live_bytes() !== 0) fail(`${tag}: live bytes ${res.x.live_bytes()} after the trap`);
    const next = await small(tag);
    if (next.x.stack_canary_ok() !== 1) fail(`${tag}: canary broken after the trap`);
    break;
  }
  if (!trapped) fail(`no trap up to depth 20000${alloc ? ' alloc' : ''}: the test proves nothing`);
}
// Free mode, on a fresh runner (an intact canary): depths up to the first trap, 2 frames apart.
{
  const f = makeRunner(module, async () => 'x');
  let d = 3000, res, bodies = 0;
  for (; d <= 20000; d += d < 4000 ? 500 : 2) {
    res = await f.run(`${d} free`);
    if (res.body === undefined) break;
    bodies++;
    if (f.x.stack_canary_ok() !== 1) {
      fail(`free ${d}: a body with a broken canary (the free ran below the canary limit)`);
      break;
    }
    if (res.body !== ref(d, false, true)) fail(`free ${d}: wrong body ${res.body}`);
  }
  if (res.body === undefined) {
    console.log(`free: ${bodies} bodies, canary intact; depth ${d} trap:`, String(res.trap).slice(0, 60), '| retired', f.stats.retired > 0);
    if (f.stats.retired || f.stats.walkFailed) fail(`free ${d}: the trap was not clean`);
    if (f.x.live_bytes() !== 0) fail(`free ${d}: live bytes ${f.x.live_bytes()} after the trap`);
    const a = await f.run('5 free');
    if (a.body !== ref(5, false, true)) fail(`free ${d}: next request gave ${a.body ?? a.trap}`);
    if (f.x.live_bytes() !== 0 || f.x.dealloc_miss() !== 0) fail(`free ${d}: live bytes ${f.x.live_bytes()}, dealloc_miss ${f.x.dealloc_miss()} at the end`);
  } else if (d > 20000) fail('free: no trap up to depth 20000');
}
// V2: a trap at normal depth must stay unclean, also in a stack-first build. After 12c it is an
// alarm: `task_abort` gives -1, the alarm counter of the host goes up, and the instance stays
// while the global check passes.
{
  if (r.stats.walkFailed !== 0) fail(`an overflow trap was unclean (${r.stats.walkFailed})`);
  for (const [kind, what] of [[1, 'out-of-bounds write'], [2, 'unreachable']]) {
    const x = r.x;
    const was = { retired: r.stats.retired, host: x.alarms(), alarmChecks: r.stats.byCheck.alarm };
    x.fault_next_wait(kind);
    const res = await r.run('5');
    const host = x.alarms() - was.host;
    if (res.body !== undefined) fail(`V2 ${what}: no trap`);
    else if (res.alarm !== 'trap' || res.status !== 503) fail(`V2 ${what}: a trap at normal depth is not an alarm (${res.alarm}, ${res.status})`);
    if (host !== 1) fail(`V2 ${what}: the alarm counter of the host went up by ${host}, want 1`);
    if (r.stats.byCheck.alarm !== (was.alarmChecks ?? 0) + 1 || r.stats.heapFails) fail(`V2 ${what}: no passed global check after the alarm`);
    if (r.stats.retired !== was.retired || r.x !== x) fail(`V2 ${what}: the alarm replaced the instance`);
    console.log('V2', what, 'trap:', String(res.trap).slice(0, 50), '| alarm', res.alarm, '| host alarms +', host, '| replaced', r.x !== x);
    await small(`V2 ${what}`);
  }
}
const live = r.x.live_bytes();
if (live !== 0) fail(`live bytes ${live} at the end`);
console.log(failures.length ? `FAIL (${failures.length})` : 'PASS', JSON.stringify(r.stats));
process.exit(failures.length ? 1 : 0);
