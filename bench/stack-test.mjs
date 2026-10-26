// PLAN.md 12a-stack: test of the stack copy. node bench/stack-test.mjs bench/out/app_stack.wasm [rounds=5]
// First the probe: the deepest depth `max` that fits in the stack (one task alone, 3 waits). The frame size comes from
// the compiler (256 B per level with nightly 10-12 before 8h wave C, about 470 B after it), so a fixed depth is not
// sound: depth 4,000 overflowed the 1 MiB stack after 8h wave C, and the test failed (first release run, PLAN.md).
// Each round: 64 tasks at random depths from 10 to `max` (bench/app_stack.roc), each with a canary in each frame, and
// 3 waits at the bottom. The io of each wait ends after a random delay, so the tasks wait and resume in random order.
// Each frame checks its canary after the waits. Expect "bad=0" from each task, a largest copy of at least 90 % of the
// stack, and live bytes 0 at the end.
// Then the overflow rounds (first release run). Round A: 4 of the 64 tasks go to depth 2 * max, so they overflow while
// the others wait. Round B: all 64 wait once on one barrier, so all resumes are in one promise job queue, and 4 of them
// recurse 2 * max levels after the resume (`<after>` of bench/app_stack.roc). Expect in each: each of the 4 is a clean
// trap (no alarm), and the 60 others give "bad=0". Before the fix, a task that entered wasm (round A: a new run, round
// B: a resume) after the overflow and before the catch of that task (`task_abort`) found the wrapped stack pointer and
// trapped too: alarms, a failed global check, a new instance (js/wait.js `enterWasm`).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';

// The stack size in the header of bench/platform/main.roc (`initial_stack_size`).
const STACK = 1048576;
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const rounds = Number(process.argv[3] ?? 5);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// `barrier`: while it is set, each io ends when it settles (all resumes in one promise job queue).
let barrier = null;
const io = async () => {
  await (barrier ?? sleep(Math.random() * 10));
  return 'x';
};
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};

// The probe: binary search on a runner of its own. A depth fits when its body is "bad=0", and it overflows when it
// is a clean trap. Anything else is a failure.
const probe = makeRunner(module, io);
const fits = async (d) => {
  const x = await probe.run(`7 ${d} 3`);
  if (x.body === 'bad=0') return true;
  if (x.trap !== undefined && x.alarm === undefined) return false;
  fail(`probe depth ${d}:`, x.body ?? x.trap);
  return false;
};
let lo = 10, hi = 100000;
if (!(await fits(lo))) fail('depth 10 does not fit');
while (hi - lo > 1) {
  const mid = (lo + hi) >> 1;
  if (await fits(mid)) lo = mid;
  else hi = mid;
}
const max = lo;
if (probe.stats.alarms !== 0 || probe.stats.retired !== 0) fail('probe: an overflow was not clean', probe.stats.alarms, probe.stats.retired);

const r = makeRunner(module, io);
let bad = 0, tasks = 0, minD = Infinity, maxD = 0;
for (let k = 0; k < rounds; k++) {
  const depths = Array.from({ length: 64 }, (_, i) => (i === 0 ? 10 : i === 1 ? max : 10 + Math.floor(Math.random() * (max - 9))));
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
const saved = x.task_saved_max();
console.log({ max, bytesPerLevel: Math.round(saved / max), tasks, bad, depths: `${minD} to ${maxD}`, savedMaxBytes: saved, waits: x.task_waits(), live: x.live_bytes(), replaced: r.stats.retired });
if (bad !== 0 || x.live_bytes() !== 0 || r.stats.retired !== 0) fail('rounds: a wrong canary, a trap, live bytes, or a new instance');
if (saved < 0.9 * STACK) fail(`rounds: the largest copy is ${saved} B, less than 90 % of the stack`);

// The overflow rounds: tasks 3, 17, 33, 49 overflow.
const deep = new Set([3, 17, 33, 49]);
async function overflowRound(name, req, hold) {
  let release;
  if (hold) barrier = new Promise((r) => (release = r));
  const depths = Array.from({ length: 64 }, () => 10 + Math.floor(Math.random() * (max - 9)));
  const running = Promise.all(depths.map((d, i) => r.run(req(i, d))));
  if (hold) {
    await sleep(30);
    release();
  }
  const res = await running;
  barrier = null;
  let wrong = 0, clean = 0;
  res.forEach((y, i) => {
    if (deep.has(i)) {
      if (y.trap !== undefined && y.alarm === undefined) clean++;
      else if (wrong++ < 4) console.log(`BAD ${name} overflow:`, y.body ?? y.trap);
    } else if (y.body !== 'bad=0' && wrong++ < 4) console.log(`BAD ${name} depth ${depths[i]}:`, y.body ?? y.trap);
  });
  await sleep(20);
  const s = r.stats;
  console.log({ [name]: { clean, wrong, alarms: s.alarms, heapFails: s.heapFails, replaced: s.retired, live: r.x.live_bytes() } });
  if (clean !== deep.size || wrong !== 0 || s.alarms !== 0 || s.heapFails !== 0 || s.retired !== 0 || r.x.live_bytes() !== 0)
    fail(`${name}: an overflow while other tasks wait is not clean, or another task failed`);
}
await overflowRound('overflow at the start', (i, d) => `${90000 + i} ${deep.has(i) ? 2 * max : d} 3`, false);
await overflowRound('overflow after a resume', (i, d) => `${91000 + i} ${d} 1 ${deep.has(i) ? 2 * max : 0}`, true);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
