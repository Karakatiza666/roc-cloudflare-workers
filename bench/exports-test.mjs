// PLAN.md 7a: the two export lists. Usage: node bench/exports-test.mjs bench/out/app_prod.wasm [bench/out/app.wasm]
// 1. The shared parts of platform/main.roc and bench/platform/main.roc (all but the comments and `exports:`) are
//    equal, and each other module file of platform/ has an equal copy in bench/platform/ (8a: Js, Io, Host).
// 2. The production header lists exactly PRODUCTION (below), and the bench header lists PRODUCTION and more.
// 3. The export section of the production build has PRODUCTION and nothing else (no bench name), and the
//    production host object (platform/targets/wasm32/host.wasm) has no symbol of a bench name.
// 4. The production build serves requests as bench/node-test.mjs does (200 + 200 at once, 4 traps, both variants)
//    with the runner of bench/core.js: it needs no bench export. The runner refuses `resumeCheck: "off"` there.
// 5. With a bench build: its export section is the bench header list, and the runner accepts "off".
// Exit 1 on a failure.
import { readFileSync, readdirSync } from 'node:fs';
import { makeRunner, check } from './core.js';

// The production list of PLAN.md 7a, the one place that says it. The 7a row names `set_sum` and `set_suspect` in
// the 12b status (JS needs both), and `sum_checks` as a counter export.
const PRODUCTION = [
  'init', 'handle', 'task_abort', 'task_cancel', 'task_slots', 'js_alloc', 'res_free', 'stack_first', 'set_free_mark',
  'set_grow_step', 'check_heap', 'log_ptr', 'log_len', 'log_clear', 'heap_used', 'heap_bytes', 'live_bytes', 'live_peak',
  'reclaim_walks', 'reclaim_bytes', 'leaked_at_end', 'idle_resets', 'idle_reset_bytes', 'alarms', 'sum_checks',
  'double_frees', 'dealloc_miss', 'idle_reset', 'trap_cause', 'set_sum', 'set_suspect', '__instance_signal',
  '__instance_terminated',
];

let failed = false;
const fail = (msg) => {
  failed = true;
  console.log('FAIL', msg);
};
const same = (a, b) => a.length === b.length && a.every((x) => b.includes(x));
const diff = (a, b) => a.filter((x) => !b.includes(x));

const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), 'utf8');
const exportsOf = (header) => {
  const m = header.match(/exports:\s*\[([^\]]*)\]/);
  return m ? [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]) : null;
};
// The header with no comment lines and no `exports:` line: the part that both files must share.
const shared = (header) => header.split('\n').filter((l) => !/^\s*#/.test(l) && !/^\s*exports:/.test(l)).join('\n');
const wasmExports = (file) => WebAssembly.Module.exports(new WebAssembly.Module(readFileSync(file))).map((e) => e.name).filter((n) => n !== 'memory');

// 1, 2: the headers
const prodHeader = read('platform/main.roc');
const benchHeader = read('bench/platform/main.roc');
const prodList = exportsOf(prodHeader);
const benchList = exportsOf(benchHeader);
if (shared(prodHeader) !== shared(benchHeader)) fail('platform/main.roc and bench/platform/main.roc differ outside `exports:`');
// The modules of the platform: bench/platform/ has a copy of each (a platform holds all its files).
const modules = (dir) => readdirSync(new URL(`../${dir}`, import.meta.url)).filter((f) => f.endsWith('.roc') && f !== 'main.roc').sort();
if (modules('platform').join() !== modules('bench/platform').join()) fail(`the module files differ: platform/ [${modules('platform')}], bench/platform/ [${modules('bench/platform')}]`);
for (const f of modules('platform')) if (read(`platform/${f}`) !== read(`bench/platform/${f}`)) fail(`platform/${f} and bench/platform/${f} differ`);
if (!prodList || !benchList) fail('no `exports:` list in a header');
else {
  if (new Set(prodList).size !== prodList.length || new Set(benchList).size !== benchList.length) fail('a name twice in an exports list');
  if (!same(prodList, PRODUCTION)) fail(`platform/main.roc exports differ from the production list: extra [${diff(prodList, PRODUCTION)}], missing [${diff(PRODUCTION, prodList)}]`);
  if (diff(PRODUCTION, benchList).length) fail(`bench/platform/main.roc misses production names: ${diff(PRODUCTION, benchList)}`);
}
const BENCH_ONLY = diff(benchList ?? [], PRODUCTION);
console.log(`headers: ${PRODUCTION.length} production names, ${BENCH_ONLY.length} bench only names`);

// 3: the production build
const prodFile = process.argv[2];
const benchFile = process.argv[3];
if (!prodFile) {
  console.error('usage: exports-test.mjs <app_prod.wasm> [<bench app.wasm>]');
  process.exit(2);
}
const prodNames = wasmExports(prodFile);
const leaked = prodNames.filter((n) => BENCH_ONLY.includes(n));
if (leaked.length) fail(`bench exports in the production build: ${leaked}`);
if (!same(prodNames, PRODUCTION)) fail(`the production build exports differ from the list: extra [${diff(prodNames, PRODUCTION)}], missing [${diff(PRODUCTION, prodNames)}]`);
console.log(`${prodFile}: ${prodNames.length} exports, ${leaked.length} bench names`);
// The production host object (platform/targets/wasm32/host.wasm) has no code for the bench exports: no symbol of
// their names. The linker drops an unlisted export, so only this shows that `zig build` left them out.
const hostObj = readFileSync(new URL('../platform/targets/wasm32/host.wasm', import.meta.url)).toString('latin1');
const inHost = BENCH_ONLY.filter((n) => new RegExp(`(^|[^A-Za-z0-9_])${n}([^A-Za-z0-9_]|$)`).test(hostObj));
if (inHost.length) fail(`bench names in the production host object: ${inHost}`);
console.log(`platform/targets/wasm32/host.wasm: ${inHost.length} bench names`);

// 4: requests on the production build (as bench/node-test.mjs)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const io = async (kind, a, b) => {
  if (kind === 1) {
    await sleep(5);
    return 'f:' + new URL(b).searchParams.get('id');
  }
  await sleep(1);
  return 'd:' + a.split(' ')[1];
};
const module = new WebAssembly.Module(readFileSync(prodFile));
for (const v of ['a', 'b']) {
  const r = makeRunner(module, v, io, { isolateBytes: 2 ** 40 });
  const one = await r.run('123 0');
  if (!one.body || !check('123', one.body)) fail(`${v}: first request: ${JSON.stringify(one).slice(0, 100)}`);
  let bad = 0;
  let traps = 0;
  for (const [base, withTraps] of [[1000, true], [2000, false]]) {
    const ids = Array.from({ length: 200 }, (_, i) => String(base + i));
    const res = await Promise.all(ids.map((id, i) => r.run(`${id} ${withTraps && i % 50 === 7 ? 1 : 0}`)));
    res.forEach((x, i) => {
      if (x.trap) traps++;
      else if (!check(ids[i], x.body)) bad++;
    });
  }
  // The counters of the runner read the counter exports only. The global check passes.
  const c = r.counters();
  const live = r.x.live_bytes();
  const checkCode = v === 'b' ? r.x.check_heap() : 0;
  console.log(v, { bad, traps, live, alarms: r.stats.alarms, retired: r.stats.retired, heapFails: r.stats.heapFails, heapChecks: r.stats.heapChecks, check_heap: checkCode, heapUsed: c.heapUsed });
  if (bad !== 0 || traps !== 4 || live !== 0) fail(`${v}: bad ${bad}, traps ${traps}, live bytes ${live}`);
  if (r.stats.alarms !== 0 || r.stats.retired !== 0 || r.stats.heapFails !== 0) fail(`${v}: an alarm, a replace or a failed check`);
  if (checkCode !== 0) fail(`${v}: check_heap gave ${checkCode}`);
}
// The sum mode "off" is bench only: the production host refuses it (`set_sum(0)` gives 0).
let refused = false;
try {
  makeRunner(module, 'b', io, { resumeCheck: 'off' });
} catch (e) {
  refused = /bench host/.test(String(e));
}
if (!refused) fail('the production build accepts resumeCheck "off"');
console.log('resumeCheck "off" refused on the production build:', refused);

// 5: the bench build
if (benchFile) {
  const names = wasmExports(benchFile);
  if (!same(names, benchList ?? [])) fail(`the bench build exports differ from bench/platform/main.roc: extra [${diff(names, benchList ?? [])}], missing [${diff(benchList ?? [], names)}]`);
  try {
    const r = makeRunner(new WebAssembly.Module(readFileSync(benchFile)), 'b', io, { resumeCheck: 'off' });
    const x = await r.run('7 0');
    if (!x.body || !check('7', x.body)) fail('bench build, resumeCheck "off": bad body');
    console.log(`${benchFile}: ${names.length} exports, resumeCheck "off" accepted`);
  } catch (e) {
    fail(`the bench build refuses resumeCheck "off": ${e}`);
  }
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
