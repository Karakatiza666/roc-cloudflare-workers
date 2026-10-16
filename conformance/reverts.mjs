// node conformance/reverts.mjs [name-filter]   (env: ROC; MINIFLARE as run.mjs)
// Revert checks of PLAN.md 8c, wave 1 and 8d. Each revert is a real edit of a source file, a build of the conformance app
// into .cache/conformance-reverts/ when a .roc file changed, a run of the test that must catch it, and a restore of the
// file. A change that finds no text to replace is an error (the code moved: update this list).
// The conformance app is on the bench platform, so a Roc edit is in bench/platform/ (the copy of platform/). The MC10
// revert edits platform/Time.roc, which `roc test platform/main.roc` reads. Exit 1 when a revert is not caught.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ROC = process.env.ROC;
if (!ROC) throw new Error('set ROC');
const out = `${root}.cache/conformance-reverts`;
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache` };
const BP = 'bench/platform/';
// The tests. `conformance`: run.mjs, which prints `FAIL <name>`; the others: a command whose exit code is the result.
const TESTS = {
  conformance: () => [process.execPath, ['conformance/run.mjs', `${out}/conformance.wasm`]],
  'roc test': () => [ROC, ['test', 'platform/main.roc']],
  'must-not-compile': () => ['bash', ['conformance/must-not-compile.sh']],
  'handler-test': () => [process.execPath, ['bench/handler-test.mjs', 'bench/out/app.wasm', 'bench/out/app_prod.wasm']],
};
// name, the test, the checks that must fail (conformance only), edits: [file, from, to].
const R = (name, test, checks, ...edits) => ({ name, test, checks, edits });
const reverts = [
  // A wrong JS method name in one function of each module: its route fails.
  R('Http: fetch is called "fetchx"', 'conformance', ['http send!', 'http get!', 'http open!'], [BP + 'Http.roc', 'Call(Root("global"), "fetch",', 'Call(Root("global"), "fetchx",']),
  R('Env.json!: JSON.stringify is called "stringifyx"', 'conformance', ['env json!'], [BP + 'Env.roc', 'Call(Slot(0), "stringify",', 'Call(Slot(0), "stringifyx",']),
  R('Time.sleep: scheduler.wait is called "waitx"', 'conformance', ['time sleep!', 'time sleep (Io twin)', 'time sleep in Io.race!'], [BP + 'Time.roc', 'Call(Slot(0), "wait",', 'Call(Slot(0), "waitx",']),
  R('Time.now_ms!: Date.now is called "nowx"', 'conformance', ['time now_ms!'], [BP + 'Time.roc', 'Call(Slot(0), "now", [])', 'Call(Slot(0), "nowx", [])']),
  R('Log.info!: console.info is called "infox"', 'conformance', ['log info!'], [BP + 'Log.roc', 'write!("info", line(', 'write!("infox", line(']),
  R('RateLimit.limit: the binding method is called "limitx"', 'conformance', ['ratelimit limit!', 'ratelimit limit (Io twin)'], [BP + 'RateLimit.roc', 'Call(Slot(0), "limit",', 'Call(Slot(0), "limitx",']),
  // PLAN.md 8d.
  R('Http: no map (HttpErr for each throw)', 'conformance', ['http 8d: a closed port is Network', 'http 8d: a host that does not exist is Network', 'http send_with! timeout_ms'],
    [BP + 'Http.roc', '} else if t.name == "TypeError" {', '} else if Bool.True {']),
  R('Http: map by the message "Network connection lost" only', 'conformance', ['http 8d: a host that does not exist is Network'],
    [BP + 'Http.roc', '} else if t.name == "TypeError" {', '} else if !t.message.contains("Network connection lost") {']),
  // PLAN.md 8c: Request.Cf.
  R('Request.Cf: the shim reads null as an empty text', 'conformance', ['request cf: colo Ok, a field that is not set Err(Missing)'],
    ['js/events.js', 'for (const [name, js, ok] of CF) out[name] = ok(cf[js]) ? { Ok: cf[js] } : MISSING;', "for (const [name, js, ok] of CF) out[name] = ok === isText && cf[js] == null ? { Ok: '' } : ok(cf[js]) ? { Ok: cf[js] } : MISSING;"]),
  // PLAN.md 8c: the MC10 conversion rounds down.
  R('Time.seconds_up rounds down', 'roc test', [], ['platform/Time.roc', 'seconds_up = |ms| ms // 1000 + (if ms % 1000 > 0 1 else 0)', 'seconds_up = |ms| ms // 1000']),
  // MODULES.md 10: a Secret over a bare Str gets the codecs of Str (roc-lang/roc#12309).
  R('Secret :: Str', 'must-not-compile', [], [BP + 'Secret.roc', 'Secret :: { text : Str }.{', 'Secret :: Str.{'], [BP + 'Secret.roc', 'from_str = |text| Secret.{ text }', 'from_str = |text| Secret.(text)'],
    [BP + 'Secret.roc', 'reveal = |s| s.text', 'reveal = |s| match s {\n\t\tSecret.(t) => t\n\t}']),
  // PLAN.md 8a O4: the old check of `ops` (functions only).
  R('ops: functions only', 'conformance', ['start'], ['js/options.js', "Object.values(v).every(isOp)", 'Object.values(v).every(isFn)']),
  R('ops: functions only (handler-test)', 'handler-test', [], ['js/options.js', "Object.values(v).every(isOp)", 'Object.values(v).every(isFn)']),
  // A null body (204) is no bytes in pf.readUpTo.
  R('readUpTo: no null branch', 'conformance', ['http send! of a 204 (no body)'], ['js/helpers.js', '      if (stream === null) return new Uint8Array(0);\n', '']),
];

const filter = process.argv[2];
const sh = (cmd, args) => spawnSync(cmd, args, { cwd: root, env, encoding: 'utf8', timeout: 600000 });
const build = () => {
  mkdirSync(out, { recursive: true });
  const r = sh(ROC, ['build', '--opt=speed', '--target=wasm32', '--no-cache', `--output=${out}/conformance.wasm`, 'conformance/app.roc']);
  return r.status === 0 || r.status === 2 ? null : `roc build failed: ${(r.stdout + r.stderr).slice(-400)}`;
};
const test = (name) => {
  const [cmd, args] = TESTS[name]();
  const r = sh(cmd, args);
  const text = r.stdout + r.stderr;
  return { pass: r.status === 0, lines: text.split('\n').filter((l) => l.startsWith('FAIL ')), text };
};

let bad = false;
const cleanBuild = build();
if (cleanBuild) {
  console.log(`the clean tree: ${cleanBuild}`);
  process.exit(1);
}
for (const name of Object.keys(TESTS)) {
  const c = test(name);
  if (!c.pass) {
    console.log(`the clean tree fails ${name}: ${c.text.slice(-600)}`);
    process.exit(1);
  }
}
console.log('clean tree: PASS');
let built = true;
for (const rv of reverts) {
  if (filter && !rv.name.includes(filter)) continue;
  const saved = new Map();
  try {
    for (const [f, from, to] of rv.edits) {
      if (!saved.has(f)) saved.set(f, readFileSync(root + f, 'utf8'));
      const s = readFileSync(root + f, 'utf8');
      if (!s.includes(from)) throw new Error(`no text to replace in ${f}: ${from.slice(0, 60)}`);
      writeFileSync(root + f, s.replace(from, to));
    }
    const roc = rv.edits.some(([f]) => f.endsWith('.roc'));
    if (rv.test === 'conformance' && (roc || !built)) {
      const err = build();
      if (err) {
        console.log(`${rv.name}: ${err}`);
        bad = true;
        continue;
      }
      built = !roc;
    }
    const t = test(rv.test);
    const caught = !t.pass && rv.checks.every((c) => t.lines.some((l) => l.startsWith(`FAIL ${c}: `)));
    const where = rv.test === 'conformance' ? `${t.lines.length} checks FAIL` : `${rv.test} FAILED`;
    console.log(`${rv.name}: ${t.pass ? `NOT CAUGHT (${rv.test} passed)` : where}${caught || t.pass ? '' : `, but not in all of [${rv.checks.join('; ')}]`}`);
    const line = t.text.split('\n').find((l) => l.startsWith('FAIL') || l.includes('✗') || l.includes('FAIL'));
    if (line) console.log(`  first: ${line.slice(0, 240)}`);
    if (!caught) bad = true;
  } finally {
    for (const [f, text] of saved) writeFileSync(root + f, text);
  }
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
