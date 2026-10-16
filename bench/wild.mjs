// Wild writes (PLAN.md 12a, from research/alloc/scripts/wild.mjs):
// node bench/wild.mjs bench/out/app.wasm <words> [n=20000] [rate=0.005] [latMs=20] [resumeCheck=always] [trap=later]
// n requests, 64 at once, io with an exponential delay (mean latMs). A share `rate` of them write
// `words` random words into memory at their first wait (test export `fault_next_wait`). trap "later"
// (5): the writer waits and traps after its resume, so other tasks resume onto the damage first.
// trap "now" (4, the research hook): it traps at once. The runner then replaces the instance before
// any other task resumes (4a, 3c), so "now" finds wrong bodies with no sums too only by chance.
// The other requests must never give a wrong body with status 200. resumeCheck "off" (no sums) is
// the revert check: then wrong bodies are expected.
// 12c: an alarm does not replace the instance. The global check runs after each alarm, and only a
// failed check replaces it: replaces = failed checks, and never 2 instances with tasks.
// Exit 1 when a wrong body comes back, when an instance is replaced with no failed check, or when
// `run` throws (12c: a trap in any export on a damaged instance is an alarm).
import { readFileSync } from 'node:fs';
import { makeRunner, check } from './core.js';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const [words, n = 20000, rate = 0.005, lat = 20] = process.argv.slice(3, 7).map(Number);
const resumeCheck = process.argv[7] ?? 'always';
const trapAt = process.argv[8] ?? 'later';
const DEPTH = 20, ITEMS = 50;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  await sleep(-Math.log(1 - Math.random()) * lat);
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
const lines = {};
// One count per kind of log line. A failed check: per check code (`heap check failed (why): <code> <name>`).
const log = (text) => { const k = text.startsWith('heap check failed') ? text.split(';')[0] : text.split(':')[0]; lines[k] = (lines[k] ?? 0) + 1; };
const r = makeRunner(module, io, { resumeCheck, log });
let seed = 7, i = 0;
const s = { good: 0, badBody: 0, wild: 0, alarmSum: 0, alarmBlock: 0, trap: 0, cancelled: 0, otherErr: 0 };
async function worker() {
  while (i < n) {
    const id = String(100000 + i++);
    const wild = Math.random() < rate;
    if (wild) {
      // The task of the next `run` reaches its first wait in this call: the write hits it.
      r.x.set_wild(seed++, words);
      r.x.fault_next_wait(trapAt === 'now' ? 4 : 5);
    }
    let res;
    try {
      res = await r.run(`${id} 0 ${DEPTH} ${ITEMS}`);
    } catch (e) {
      if (!s.otherErr++) console.log('first error of run:', e);
      continue;
    }
    if (wild) s.wild++;
    else if (res.body !== undefined) check(id, res.body, DEPTH) ? s.good++ : s.badBody++;
    else if (res.alarm === 'sum') s.alarmSum++;
    else if (res.alarm === 'block') s.alarmBlock++;
    else if (res.cancelled) s.cancelled++;
    else s.trap++;
  }
}
let maxLive = 0;
const sample = setInterval(() => { maxLive = Math.max(maxLive, r.tasks.liveInstances()); }, 1);
await Promise.all(Array.from({ length: 64 }, worker));
clearInterval(sample);
const st = r.stats;
console.log(JSON.stringify({ resumeCheck, trapAt, words, n, rate, ...s, replaced: st.retired, heapChecks: st.heapChecks, heapFails: st.heapFails, byCheck: st.byCheck, maxLive, logLines: lines, checkMsMax: +st.heapCheckMaxMs.toFixed(3) }));
const sameInstance = st.retired === st.heapFails && maxLive <= 1;
if (!sameInstance) console.log(`FAIL: ${st.retired} replaces, ${st.heapFails} failed checks: an alarm replaced the instance`);
if (s.otherErr) console.log(`FAIL: run threw ${s.otherErr} times`);
process.exit(s.badBody === 0 && sameInstance && s.otherErr === 0 ? 0 : 1);
