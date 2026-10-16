// PLAN.md 8e: the tests of `Native` (API.md 8) with bench/app_native.roc in Node.
// node bench/native-test.mjs bench/out/app_native.wasm [only]   (only: a test name, for a revert check)
// The data is research/native/data/. The references: `zstd -d` (the CLI, when it is installed), the `.sha256` files,
// and `hashes.txt` (BLAKE3 from the official Python package `blake3`, SHA-256 from `sha256sum`).
// Each test sends requests "<case> <args>" and checks the body and the memory of the instance.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { makeRunner } from './core.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const only = process.argv[3];
const DATA = new URL('../research/native/data/', import.meta.url);
const file = (n) => readFileSync(new URL(n, DATA));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const sha = (b) => createHash('sha256').update(b).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The references.
const hashes = Object.fromEntries(readFileSync(new URL('hashes.txt', DATA), 'utf8').trim().split('\n').map((l) => {
  const [name, b3, s] = l.split(' ');
  return [name, { b3, sha: s }];
}));
const cli = spawnSync('zstd', ['--version']).status === 0;
// The unpacked bytes of a .zst file: the CLI when there is one, else the known tar.
const unpack = (n) => {
  if (cli) return spawnSync('zstd', ['-d', '-c', '-q', new URL(n, DATA).pathname], { maxBuffer: 1 << 28 }).stdout;
  return null;
};

// The test controls `gate`: a request waits there until `open` or the end of a mode.
let gates = [];
let autoGate = true;
// `armAlloc`: the n-th allocation after the wait fails (the host `fail_alloc_at`).
let armAlloc = 0;
const ops = {
  data: (name) => file(name),
  gate: () => {
    if (armAlloc) {
      r.x.fail_alloc_at(armAlloc);
      armAlloc = 0;
    }
    return autoGate ? Promise.resolve(1) : new Promise((res) => gates.push(res));
  },
};
const logs = [];
const newRunner = () => makeRunner(module, 'b', null, { ops, isolateBytes: 2 ** 40, log: (t) => logs.push(t), onLog: (level, t) => logs.push(t) });
let r = newRunner();
if (r.stats.fallback) {
  console.log('FAIL: the module is not stack-first');
  process.exit(1);
}
const show = (x) => x.body ?? `trap ${x.status ?? ''} ${x.cause ?? x.alarm ?? ''} ${x.trap}`;
const tests = [];
const test = (name, f) => tests.push([name, f]);
const expectBody = (name, x, want) => {
  const ok = want instanceof RegExp ? want.test(x.body ?? '') : x.body === want;
  if (!ok) fail(`${name}: got ${show(x)}, want ${want}`);
  return ok;
};
const idle = (what) => {
  if (r.x.live_bytes() !== 0) fail(`${what}: live bytes ${r.x.live_bytes()}`);
  if (r.x.native_slots() !== 0) fail(`${what}: ${r.x.native_slots()} handles in use`);
};

test('decode', async () => {
  // A package .tar.zst: the bytes are the bytes of `zstd -d` (a SHA-256 compare), for 4 variants of one package,
  // and a real package that `roc bundle` made.
  const rows = [];
  for (const n of ['pkg.tar.zst', 'pkg-pipe.tar.zst', 'pkg-nocheck.tar.zst', 'pkg-w24.tar.zst', 'roc-parser.tar.zst']) {
    const want = n.startsWith('roc-parser') ? readFileSync(new URL('roc-parser.sha256', DATA), 'utf8').trim() : hashes['pkg.tar'].sha;
    const ref = unpack(n);
    if (ref && sha(ref) !== want) fail(`decode ${n}: the reference file differs from zstd -d`);
    const x = await r.run(`decode ${n} 1000000000`);
    const len = ref ? ref.length : (n.startsWith('roc-parser') ? null : 122880);
    const ok = len === null ? new RegExp(`^ok \\d+ ${want}$`).test(x.body ?? '') : x.body === `ok ${len} ${want}`;
    if (!ok) fail(`decode ${n}: got ${show(x)}, want ok ${len} ${want}`);
    rows.push(`${n} ${(x.body ?? '').split(' ')[1]}`);
  }
  idle('decode');
  return `${rows.join(', ')}; zstd CLI ${cli ? 'checked' : 'not installed'}`;
});

test('limit', async () => {
  // A 149 byte archive of 4 MiB of zeros: with a limit of 256 KB the decode stops at the limit and the memory stays
  // near the limit. Revert (no limit): `ok` and a peak of the whole output.
  r = newRunner();
  const base = r.x.live_peak();
  const x = await r.run('decode zeros.zst 262144');
  expectBody('limit', x, 'err OutputLimit');
  const peak = r.x.live_peak() - base;
  // The limit and one block over it (128 KB), the input (149 B) and the request: far under the 4 MiB of the output.
  if (peak > 1024 * 1024) fail(`limit: the peak grew by ${peak} B, want under 1 MiB (the output is 4 MiB)`);
  // Control: the exact limit works, one byte less does not.
  const ok = await r.run('decode zeros.zst 4194304');
  expectBody('limit exact', ok, /^ok 4194304 /);
  const peakOk = r.x.live_peak() - base;
  if (peakOk < 4 * 1024 * 1024) fail(`limit: the control decode peaked at ${peakOk} B, want at least 4 MiB (the test proves nothing)`);
  expectBody('limit one under', await r.run('decode zeros.zst 4194303'), 'err OutputLimit');
  idle('limit');
  return `${show(x)}, peak +${peak} B; exact: ${ok.body.slice(0, 10)}, peak +${peakOk} B`;
});

test('hash', async () => {
  // BLAKE3 and SHA-256 of a file in chunks of 64 KB (and of 1,000 B and 1 B) equal the references.
  const rows = [];
  for (const n of ['pkg.tar', 'multi.tar', 'odd.bin', 'empty.bin']) {
    for (const chunk of [65536, 1000, 1]) {
      if (chunk === 1 && file(n).length > 130000) continue;
      const x = await r.run(`hash ${n} ${chunk}`);
      expectBody(`hash ${n} ${chunk}`, x, `b3=${hashes[n].b3} sha=${hashes[n].sha}`);
    }
    rows.push(`${n} ${hashes[n].b3.slice(0, 8)}`);
  }
  idle('hash');
  return rows.join(', ');
});

test('stream', async () => {
  // The stream gives the bytes of `zstd -d` for any chunk size, and `push_limit` stops it.
  const want = `ok 122880 ${hashes['pkg.tar'].sha}`;
  for (const chunk of [1, 7, 4096, 65536]) expectBody(`stream chunk ${chunk}`, await r.run(`stream pkg.tar.zst ${chunk} 0`), want);
  expectBody('stream pipe', await r.run('stream pkg-pipe.tar.zst 1000 0'), want);
  const limited = await r.run('stream zeros.zst 100000 1000');
  expectBody('stream push limit', limited, /^err OutputLimit close /);
  idle('stream');
  return `chunks 1, 7, 4096, 65536 equal; push limit: ${show(limited)}`;
});

test('handles', async () => {
  // Typed errors: a closed handle is `BadHandle`, the 17th handle of a task is `TooManyHandles`, a window limit over
  // 8 MiB is `BadArgument`.
  const twice = await r.run('twice');
  expectBody('twice', twice, 'final=Err(BadHandle) update=Err(BadHandle)');
  const many = await r.run('many');
  expectBody('many', many, 'opened 16 then TooManyHandles');
  const limits = await r.run('limits');
  expectBody('limits', limits, /^window16M=Err\(BadArgument\)$/);
  idle('handles');
  return `${show(twice)}; ${show(many)}; ${show(limits)}`;
});

test('wrongtask', async () => {
  // A handle of another task is `WrongTask` (status 1). Two tasks each open a handle and wait. The test gives the slots
  // of task A to task B (`native_reown`), so the handle that A holds is a handle of B. A uses it: `WrongTask`. B uses its
  // own: `Ok`. Revert (no owner check in `lookup`): A gets `Ok`.
  autoGate = false;
  gates = [];
  const a = r.run('wait 0');
  const b = r.run('wait 0');
  for (let t = 0; t < 2000 && gates.length < 2; t++) await sleep(1);
  if (gates.length < 2) {
    autoGate = true;
    fail('wrongtask: the tasks did not wait');
    return 'no wait';
  }
  const ids = [];
  for (let id = 1; id < 1000000 && ids.length < 2; id++) if (r.tasks.get(id)) ids.push(id);
  const idA = Math.min(...ids), idB = Math.max(...ids);
  const moved = r.x.native_reown(idA, idB);
  // A holds a BLAKE3 state and a zstd stream (the app opens the stream in `open_n!`).
  if (moved !== 2) fail(`wrongtask: ${moved} slots moved, want 2`);
  gates.forEach((g) => g(1));
  autoGate = true;
  const [xa, xb] = await Promise.all([a, b]);
  // Which of the two requests is A is the one that started first.
  expectBody('wrongtask A', xa, 'after the wait: update=Err(WrongTask)');
  expectBody('wrongtask B', xb, 'after the wait: update=Ok({})');
  idle('wrongtask');
  return `A: ${show(xa)}; B: ${show(xb)}`;
});

test('endtask', async () => {
  // A task that ends with handles open leaves live bytes 0 and no slot, by a return, by a trap and by a cancel.
  // 200 tasks with 4 handles each would fill the 64 slots of the instance if the slots stayed.
  const alarms = r.stats.alarms;
  const rows = {};
  // Return.
  let bad = 0;
  for (let i = 0; i < 20; i++) {
    const res = await Promise.all(Array.from({ length: 10 }, () => r.run('hold 3')));
    bad += res.filter((x) => x.body !== 'held 3').length;
  }
  rows.return = { bad, live: r.x.live_bytes(), slots: r.x.native_slots() };
  if (bad || rows.return.live || rows.return.slots) fail(`endtask return: ${JSON.stringify(rows.return)}`);
  // Trap.
  let traps = 0, other = 0;
  for (let i = 0; i < 100; i++) {
    const x = await r.run('crash 3');
    if (x.trap && x.status === undefined) traps++;
    else other++;
  }
  rows.trap = { traps, other, alarms: r.stats.alarms - alarms, live: r.x.live_bytes(), slots: r.x.native_slots() };
  if (traps !== 100 || other || rows.trap.alarms || rows.trap.live || rows.trap.slots) fail(`endtask trap: ${JSON.stringify(rows.trap)}`);
  // Cancel in a wait.
  autoGate = false;
  gates = [];
  let cancels = 0;
  // 10 tasks with 5 handles each: the instance has 64 slots.
  const acs = Array.from({ length: 10 }, () => new AbortController());
  const runs = acs.map((ac) => r.run('wait 3', { signal: ac.signal }).then((x) => {
    if (x.cancelled) cancels++;
  }));
  for (let t = 0; t < 2000 && gates.length < 10; t++) await sleep(1);
  acs.forEach((ac) => ac.abort());
  await Promise.all(runs);
  gates.forEach((g) => g(1));
  autoGate = true;
  await sleep(5);
  rows.cancel = { cancels, live: r.x.live_bytes(), slots: r.x.native_slots() };
  if (cancels !== 10 || rows.cancel.live || rows.cancel.slots) fail(`endtask cancel: ${JSON.stringify(rows.cancel)}`);
  return JSON.stringify(rows);
});

test('oom', async () => {
  // Status 4 of an op (the allocator gave 0) is a clean OOM trap of the task (API.md 4.1), at each allocation of
  // `new!` and `final!`: cause `oom`, no alarm, live bytes 0, no slot. Revert (status 4 is not a trap): the op gives
  // an error code and the app crashes, a trap with another cause.
  r = newRunner();
  const alarms0 = r.stats.alarms, retired0 = r.stats.retired;
  const causes = {};
  let bodies = 0, k = 1;
  for (; k <= 40; k++) {
    armAlloc = k;
    const x = await r.run('oom');
    if (x.body !== undefined) {
      if (!/^ok af1349b9/.test(x.body) && !/^ok [0-9a-f]{64}$/.test(x.body)) fail(`oom k=${k}: wrong body ${x.body}`);
      bodies++;
      if (bodies === 2) break;
      continue;
    }
    causes[x.cause] = (causes[x.cause] ?? 0) + 1;
    if (x.cause !== 'oom' || x.status !== 503) fail(`oom k=${k}: got ${show(x)}, want a 503 oom trap`);
    if (r.x.live_bytes() !== 0 || r.x.native_slots() !== 0) fail(`oom k=${k}: live ${r.x.live_bytes()}, slots ${r.x.native_slots()}`);
  }
  if (r.stats.alarms !== alarms0 || r.stats.retired !== retired0) fail('oom: a trap was not clean');
  if (r.x.check_heap() !== 0) fail('oom: check_heap failed');
  if ((causes.oom ?? 0) < 8) fail(`oom: ${causes.oom ?? 0} oom traps, want at least 8 (the sweep did not reach the ops)`);
  return `${JSON.stringify(causes)} for k = 1 to ${k - 1}, ${bodies} bodies after`;
});

test('deep', async () => {
  // README decision 3: a deep Roc recursion (bench/app_deep.roc `down`, a wide record at each level) calls `zstd_decode!`
  // at the bottom (274 KB of stack in the decoder). The result is right or the trap is clean, and the heap check passes
  // after: never damage. It finds the depth where each starts to trap.
  r = newRunner();
  const m = (x) => x % 1000003n;
  const ref = (depth, x) => {
    let salt = 17n;
    for (let k = BigInt(depth); k > 0n; k--) salt = m(salt + k * 3n);
    let q = { a: salt + x, b: 1n, c: 2n, d: 1n, e: 3n, f: 4n, g: 5n, h: 6n, i: 7n, j: 8n, k: 9n, l: 10n, m: 11n, n: 12n, o: 13n, p: 14n };
    for (let k = 1n; k <= BigInt(depth); k++) {
      q = { a: m(q.b + k), b: m(q.c * 5n + k), c: m(q.a + q.d), d: q.d + 1n, e: m(q.f + q.e), f: m(q.g + k), g: m(q.h * 3n), h: m(q.i + 1n), i: m(q.j + q.a), j: m(q.k + 2n), k: m(q.l + k), l: m(q.m + 3n), m: m(q.n + q.b), n: m(q.o + 4n), o: m(q.p + k), p: m(q.a + q.c) };
    }
    return `a=${q.a} d=${q.d} p=${q.p}`;
  };
  const out = file('pkg.tar');
  const digest = createHash('sha256').update(out).digest();
  const xDecode = BigInt(out.length) + BigInt(digest.readUInt32LE(0));
  // The canary guards the floor of the stack (hostlib/canary.zig). Nothing is below the stack (stack-first), so a frame
  // that reaches it writes over nothing else. A plain recursion has no allocation at the bottom, so it can return a body
  // with a broken canary at the very edge (the platform did that before 8e). Nobody repairs the canary after a body, so
  // the runner is replaced (`broken`) and the next probe starts clean. With `zstd_decode!` the allocations after the
  // frame check the canary, so a body with a broken canary is damage.
  let alarms0 = r.stats.alarms, retired0 = r.stats.retired;
  const state = { ok: 0, trap: 0, broken: 0 };
  const probe = async (depth, name) => {
    const x = await r.run(`deep ${depth} ${name}`);
    const want = ref(depth, name === '-' ? 0n : xDecode);
    if (x.body !== undefined) {
      state.ok++;
      if (x.body !== want) fail(`deep ${depth} ${name}: wrong body ${x.body}, want ${want} (damage)`);
      if (r.x.stack_canary_ok() !== 1) {
        state.broken++;
        if (name !== '-') fail(`deep ${depth} ${name}: a body with a broken canary`);
        r = newRunner();
        alarms0 = r.stats.alarms;
        retired0 = r.stats.retired;
      }
      return true;
    }
    state.trap++;
    if (r.stats.alarms !== alarms0 || r.stats.retired !== retired0) fail(`deep ${depth} ${name}: the trap was not clean (alarms ${r.stats.alarms - alarms0}, retired ${r.stats.retired - retired0})`);
    const code = r.x.check_heap();
    if (code !== 0) fail(`deep ${depth} ${name}: check_heap gave ${code} after the trap`);
    if (r.x.live_bytes() !== 0 || r.x.native_slots() !== 0) fail(`deep ${depth} ${name}: live ${r.x.live_bytes()}, slots ${r.x.native_slots()} after the trap`);
    // The platform repairs the canary after a clean trap: the next request is right and the canary is whole.
    const next = await r.run(`deep 5 ${name}`);
    if (next.body !== ref(5, name === '-' ? 0n : xDecode)) fail(`deep ${depth} ${name}: the next request gave ${show(next)}`);
    if (r.x.stack_canary_ok() !== 1) fail(`deep ${depth} ${name}: canary broken after the trap`);
    return false;
  };
  // The first depth that traps: a step of 200, then a bisection.
  const first = async (name, from) => {
    let lo = from, hi = from;
    while (await probe(hi, name)) {
      lo = hi;
      hi += 200;
      if (hi > 40000) return null;
    }
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (await probe(mid, name)) lo = mid;
      else hi = mid;
    }
    return hi;
  };
  const plain = await first('-', 1000);
  const withZstd = await first('pkg.tar.zst', 100);
  // A sweep around the edge of each: every depth from 100 below to 100 above, in steps of 1, must be right or clean.
  for (const [name, edge] of [['-', plain], ['pkg.tar.zst', withZstd]]) {
    for (let d = edge - 100; d <= edge + 100; d += 1) await probe(d, name);
  }
  const dropped = plain - withZstd;
  console.log(`deep: the plain recursion traps from depth ${plain}; with zstd_decode! at the bottom from depth ${withZstd} (${dropped} levels, about ${Math.round(274000 / dropped)} B each); ${state.ok} bodies right, ${state.trap} clean traps, ${state.broken} plain bodies with a broken canary`);
  if (!(dropped > 0)) fail('deep: zstd_decode! did not reduce the depth: the test proves nothing');
  idle('deep');
  return `plain ${plain}, zstd ${withZstd}`;
});

for (const [name, f] of tests) {
  if (only && name !== only) continue;
  try {
    console.log(`${name}: ${await f()}`);
  } catch (e) {
    fail(`${name}: threw ${e?.stack ?? e}`);
  }
}
if (!only && r.x.live_bytes() !== 0) fail(`live bytes at the end: ${r.x.live_bytes()}`);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
