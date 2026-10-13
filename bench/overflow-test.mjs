// Stack overflow test: node bench/overflow-test.mjs <app_deep.wasm> [--no-fallback] [--expect-shared]
// Requests with deeper recursion until one traps, without and with an allocation per level.
// Stack-first module (one shared instance):
//   - no request returns a body while the canary is broken, and each body is correct;
//   - the trap without allocation (out of bounds) retires the instance;
//   - the trap with allocation (canary) is clean: the instance stays;
//   - the next request is correct.
// Data-first module: the runner must fall back to an instance per request.
// --no-fallback keeps the shared instance on a data-first module. Then the test must fail.
// --expect-shared: fail when the runner falls back (CI, after check-layout.mjs found STACK-FIRST).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

const file = process.argv[2];
const noFallback = process.argv.includes('--no-fallback');
const expectShared = process.argv.includes('--expect-shared');
const module = new WebAssembly.Module(readFileSync(file));

// down() of bench/app_deep.roc.
function ref(depth, alloc) {
  const m = (x) => x % 1000003n;
  // A loop, not recursion: the salt goes down the levels, the record comes back up.
  const down = (n, salt) => {
    for (let k = n; k > 0n; k--) salt = m(salt + k * 3n);
    let r = { a: salt, b: 1n, c: 2n, d: 1n, e: 3n, f: 4n, g: 5n, h: 6n, i: 7n, j: 8n, k: 9n, l: 10n, m: 11n, n: 12n, o: 13n, p: 14n };
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
const r = makeRunner(module, 'b', async () => 'x', { noFallback });
const shared = !r.stats.fallback;
const first = r.x;
console.log(file, shared ? 'shared instance' : 'fallback: one instance per request');

const small = async (what) => {
  const a = await r.run('5');
  if (a.body !== ref(5, false)) fail(`${what}: next request gave ${a.body ?? a.trap}`);
  return a;
};

if (expectShared && !shared) fail('the runner fell back, but a shared instance was expected');
// 1b: a stack-first module shares one instance, a data-first one does not.
const s1 = await small('start');
const s2 = await small('start');
if (shared && s1.x !== s2.x) fail('shared runner used two instances');
if (!shared && s1.x === s2.x) fail('fallback runner used one instance twice');
if (shared && first.stack_first() !== 1 && !noFallback) fail('shared on a data-first module');

for (const alloc of [false, true]) {
  let trapped = false;
  for (const d of [1000, 2000, 3000, 4000, 4500, 5000, 5500, 6000, 7000, 8000, 10000, 15000, 20000]) {
    const retired = r.stats.retired;
    const res = await r.run(`${d}${alloc ? ' alloc' : ''}`);
    const tag = `depth ${d}${alloc ? ' alloc' : ''}`;
    if (res.body !== undefined) {
      const canary = res.x.stack_canary_ok();
      console.log(tag, 'ok, canary', canary);
      // Fallback: the overflow can only hit the instance of this request. That risk is known.
      if (shared && canary !== 1) fail(`${tag}: a body with a broken canary`);
      if (shared && res.body !== ref(d, alloc)) fail(`${tag}: wrong body ${res.body}`);
      continue;
    }
    trapped = true;
    const isRetired = r.stats.retired > retired;
    console.log(tag, 'trap:', res.trap.slice(0, 60), '| retired', isRetired);
    if (shared && !isRetired && !(alloc && r.x.stack_first() === 1)) fail(`${tag}: an unclean trap did not retire the instance`);
    if (shared && alloc && r.x.stack_first() === 1 && isRetired) fail(`${tag}: a canary trap retired a stack-first instance`);
    const next = await small(tag);
    if (shared && next.x.stack_canary_ok() !== 1) fail(`${tag}: canary broken after the trap`);
    break;
  }
  if (!trapped) fail(`no trap up to depth 20000${alloc ? ' alloc' : ''}: the test proves nothing`);
}
const live = r.x.live_bytes();
if (shared && live !== 0) fail(`live bytes ${live} at the end`);
console.log(failures.length ? `FAIL (${failures.length})` : 'PASS', JSON.stringify(r.stats));
process.exit(failures.length ? 1 : 0);
