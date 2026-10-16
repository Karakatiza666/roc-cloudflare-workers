// node bench/bridge-reverts.mjs [name-filter]
// Revert checks of the JS side for bench/bridge-test.mjs (PLAN.md 8a): it copies js/ and the test files to
// .cache/bridge-reverts/, breaks one rule in the copy, runs the one test that must catch it, and checks that it
// fails. The files in js/ are not changed. The reverts of the Zig host and of Roc need a build: PLAN.md 8a lists them.
// A change that finds no text to replace is an error (the code moved: update this list).
// Exit 1 when the clean copy fails, a revert is not caught, or a revert finds no text.
import { cpSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const work = `${root}.cache/bridge-reverts`;
const P = 'js/program.js', H = 'js/helpers.js', V = 'js/values.js', T = 'js/tasks.js', RN = 'js/runner.js';
// name, the test of bridge-test.mjs that must fail, edits: [file, from, to].
const R = (name, test, ...edits) => ({ name, test, edits });
const reverts = [
  R('a new id for each ref (RS1)', 'refs', [V, 'let id = this.ids.get(obj);\n    if (id === undefined) {', 'let id;\n    if (true) {']),
  R('a promise in call! is a value (OP1)', 'promise', [P, "    if (op[0] !== 'start' && op[0] !== 'keep' && isThenable(r)) {\n      // The promise is dropped", "    if (false) {\n      // The promise is dropped"]),
  R('Par runs the branches one after the other (OP6)', 'both', [P, 'r = await Promise.all(branchesOf(op).map((b) => branch(b, ctx)));', 'r = []; for (const b of branchesOf(op)) r.push(await branch(b, ctx));']),
  R('no ?. in Get (OP7)', 'null', [P, 'return o === null || o === undefined ? undefined : o[name]; // OP7: as `?.`', 'return o[name];']),
  R('Race as Par (OP8)', 'race', [P, 'r = await race(branchesOf(op), ctx);', 'r = [0, (await Promise.all(branchesOf(op).map((b) => branch(b, ctx))))[0]];']),
  R('the losers of a race are not aborted (OP8)', 'race', [P, "ctls.forEach((c, j) => { if (j !== i) c.abort(new DOMException('the branch lost the race', 'AbortError')); });", '']),
  R('findById gives the first item (6.4)', 'find', [H, 'return array.find((item) => item?.id === id);', 'return array[0];']),
  R('packEach does not pack (6.4)', 'packeach', [H, '[key]: new Packed(item?.[key], maxBytes ?? Infinity)', '[key]: item?.[key]']),
  R('a started program does not keep the context (RS1, 6.5)', 'start', [T, 'if (t.spawns === 0) freeContext(t);', 'freeContext(t);']),
  R('no ref free at a trap (10c)', 'refs10k', [RN, 'freed = x.task_abort(t.id, isStackError(e) ? 1 : 0);', 't.trapped = true;\n            freed = x.task_abort(t.id, isStackError(e) ? 1 : 0);'], [T, 'if (t.spawns === 0) freeContext(t);', 'if (t.spawns === 0 && !t.trapped) freeContext(t);']),
  R('js_alloc gives 0: status 1, not 4 (4.1)', 'oom', ['js/bridge.js', 'if (!p) return STATUS_OOM;\n  let size', 'if (!p) return 1;\n  let size']),
];

const filter = process.argv[2];
const fresh = () => {
  rmSync(work, { recursive: true, force: true });
  mkdirSync(`${work}/bench`, { recursive: true });
  cpSync(`${root}js`, `${work}/js`, { recursive: true });
  for (const f of ['bridge-test.mjs', 'core.js', 'ops.js', 'check.js']) cpSync(`${root}bench/${f}`, `${work}/bench/${f}`);
  symlinkSync(`${root}bench/out`, `${work}/bench/out`);
};
const run = (only) => {
  const args = ['bench/bridge-test.mjs', 'bench/out/app_bridge.wasm', ...(only ? [only] : [])];
  const r = spawnSync(process.execPath, args, { cwd: work, encoding: 'utf8', timeout: 120000 });
  const out = (r.stdout || '') + (r.stderr || '');
  return { failed: out.split('\n').filter((l) => l.startsWith('FAIL ')), finished: /^(PASS|FAIL)$/m.test(out), out };
};

let bad = 0;
fresh();
const base = run();
console.log(`clean copy: ${base.finished && base.failed.length === 0 ? 'all tests pass' : 'FAILS'}`);
if (!base.finished || base.failed.length) {
  console.log(base.out.slice(-1500));
  process.exit(1);
}
const rows = [];
for (const m of reverts) {
  if (filter && !m.name.includes(filter)) continue;
  fresh();
  let ok = true;
  for (const [file, from, to] of m.edits) {
    const text = readFileSync(`${work}/${file}`, 'utf8');
    if (!text.includes(from)) {
      console.log(`ERROR  ${m.name}: text not found in ${file}: ${from.slice(0, 60)}`);
      ok = false;
      break;
    }
    writeFileSync(`${work}/${file}`, text.replace(from, () => to));
  }
  if (!ok) {
    bad++;
    continue;
  }
  const r = run(m.test);
  const caught = r.finished && r.failed.some((l) => l.startsWith(`FAIL ${m.test}`));
  if (!caught) bad++;
  if (!r.finished) console.log(`${m.name}: the run did not finish:\n${r.out.slice(-1200)}`);
  rows.push({ revert: m.name, test: m.test, result: !r.finished ? 'CRASH' : caught ? 'caught' : 'NOT CAUGHT', 'first failure': (r.failed[0] || '').slice(5, 100) });
}
console.table(rows);
console.log(`${rows.filter((x) => x.result === 'caught').length} of ${rows.length} reverts caught${bad ? `, ${bad} not caught or not applied` : ''}`);
rmSync(work, { recursive: true, force: true });
process.exit(bad ? 1 : 0);
