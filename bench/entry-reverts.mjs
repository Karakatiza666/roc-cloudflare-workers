// node bench/entry-reverts.mjs [name-filter]   (env: ZIG, ROC, WORKERD)
// Revert checks for bench/entry-test.mjs (Node) and bench/entry-workerd.mjs (workerd), PLAN.md 8b (first half).
// Each revert is a real edit of a source file, a run of the tests that must catch it, and a restore of the file.
// A JS revert runs both tests on bench/out/app_events.wasm. A Zig or Roc revert builds the bench host and
// bench/app_events.roc into .cache/entry-reverts/ and runs the Node test on it. A change that finds no text to replace
// is an error (the code moved: update this list). After a build revert, it builds the clean tree again (bench/build.sh),
// because `zig build` writes the host object in place.
// Exit 1 when a revert is not caught by each check that it names, or the clean tree fails.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const { ZIG, ROC, WORKERD } = process.env;
if (!ZIG || !ROC || !WORKERD) throw new Error('set ZIG, ROC and WORKERD');
const out = `${root}.cache/entry-reverts`;
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache`, ZIG_GLOBAL_CACHE_DIR: `${root}.cache/zig` };
const I = 'js/index.js', E = 'js/events.js', W = 'platform/Worker.roc', RZ = 'hostlib/roc.zig';
// name, kind ('js' or 'build'), the checks that must fail: `node:<n>` (the FAIL lines of entry-test.mjs) and
// `workerd:<n>` (of entry-workerd.mjs), edits: [file, from, to]. A Roc file of platform/ is edited in both copies.
const R = (name, kind, checks, ...edits) => ({ name, kind, checks, edits });
const reverts = [
  R('makeHandler gives a class that does not extend WorkerEntrypoint', 'js', ['node:1'], [I, 'class Handler extends WorkerEntrypoint {', 'class Handler {']),
  R('the body crosses as a Str (request.text())', 'js', ['node:2', 'workerd:1'], [E, 'body: bodyIn(request)', 'body: request.body === null ? undefined : await request.text()']),
  R('time_ms from Date.now()', 'js', ['node:5a', 'workerd:2a'], [E, 'time_ms: Math.trunc(Number(controller.scheduledTime))', 'time_ms: Date.now()']),
  R('the shim calls noRetry on each Err', 'js', ['node:5b', 'workerd:2b'], [I, "      log(`scheduled: ${reason(r.outcome)}`);\n      throw", "      log(`scheduled: ${reason(r.outcome)}`);\n      if (r.outcome.outcome === 'failed') controller.noRetry();\n      throw"]),
  R('no method for the names of `other`', 'js', ['node:6', 'workerd:3'], [I, '  for (const name of other) {', '  for (const name of []) {']),
  R('the value of Reply does not reach the caller', 'js', ['node:6'], [I, "if (r.outcome.outcome === 'reply') return r.outcome.value;", "if (r.outcome.outcome === 'reply') return undefined;"]),
  R('Unhandled gives no log line', 'js', ['node:7', 'workerd:4a'], [I, "      log(`fetch: ${reason(r.outcome)}`);\n      return new Response(null, { status: 500 });", '      return new Response(null, { status: 500 });']),
  R('the log line of Failed has no error', 'js', ['node:8', 'workerd:4b'], [I, "(o.outcome === 'failed' ? `failed: ${o.message}`", "(o.outcome === 'failed' ? 'failed'"]),
  R('a cf field that is not set crosses as null, not in the tag form', 'js', ['node:10'], [E, '? { Ok: cf[js] } : MISSING;', '? { Ok: cf[js] } : null;']),
  R('the crash text path is off (LOG_CRASH false)', 'build', ['node:9'], [RZ, 'pub var LOG_CRASH: bool = true;', 'pub var LOG_CRASH: bool = false;']),
  R('no_retry! calls another method (noretry)', 'build', ['node:5c'], [W, 'Call(Root("event"), "noRetry", [])', 'Call(Root("event"), "noretry", [])']),
];

const filter = process.argv[2];
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: root, env, encoding: 'utf8', timeout: 600000, ...opts });
const build = () => {
  const z = sh(ZIG, ['build', '-Dbench=true']);
  if (z.status !== 0) return `zig build failed: ${z.stderr.slice(-300)}`;
  mkdirSync(out, { recursive: true });
  const r = sh(ROC, ['build', '--opt=speed', '--target=wasm32', '--no-cache', `--output=${out}/app_events.wasm`, 'bench/app_events.roc']);
  if (r.status !== 0 && r.status !== 2) return `roc build failed: ${r.stdout.slice(-300)}`;
  return null;
};
// The ids of the FAIL lines: `FAIL 5a ...` gives 5a, `FAIL 2: ...` gives 2.
const ids = (text) => [...text.matchAll(/^FAIL (\w+)[: ]/gm)].map((m) => m[1]);
const node = (wasm) => {
  const r = sh(process.execPath, ['bench/entry-test.mjs', wasm]);
  return { pass: r.status === 0, failed: ids(r.stdout + r.stderr).map((x) => `node:${x}`), text: r.stdout + r.stderr };
};
const workerd = () => {
  const r = sh(process.execPath, ['bench/entry-workerd.mjs']);
  return { pass: r.status === 0, failed: ids(r.stdout + r.stderr).map((x) => `workerd:${x}`), text: r.stdout + r.stderr };
};
// A check `node:5` is caught by a FAIL line `5`, `5a`, ...
const caughtBy = (check, failed) => failed.some((f) => f === check || (f.startsWith(check) && /^[a-z]$/.test(f.slice(check.length))));

let bad = false;
const clean = [node('bench/out/app_events.wasm'), workerd()];
if (!clean.every((t) => t.pass)) {
  console.log('the clean tree fails:', clean.map((t) => t.text.slice(-800)).join('\n'));
  process.exit(1);
}
console.log('clean tree: PASS (Node and workerd)');
let built = false;
for (const rv of reverts) {
  if (filter && !rv.name.includes(filter)) continue;
  const saved = new Map();
  try {
    for (const [f, from, to] of rv.edits) {
      for (const file of f.startsWith('platform/') ? [f, `bench/${f}`] : [f]) {
        const path = root + file;
        if (!saved.has(file)) saved.set(file, readFileSync(path, 'utf8'));
        const s = readFileSync(path, 'utf8');
        if (!s.includes(from)) throw new Error(`no text to replace in ${file}: ${from.slice(0, 60)}`);
        writeFileSync(path, s.replace(from, to));
      }
    }
    let runs;
    if (rv.kind === 'build') {
      built = true;
      const err = build();
      if (err) {
        console.log(`${rv.name}: ${err}`);
        bad = true;
        continue;
      }
      runs = [node(`${out}/app_events.wasm`)];
    } else runs = [node('bench/out/app_events.wasm'), workerd()];
    const failed = runs.flatMap((t) => t.failed);
    const caught = rv.checks.every((c) => caughtBy(c, failed));
    const passed = runs.every((t) => t.pass);
    console.log(`${rv.name}: ${passed ? 'NOT CAUGHT (the tests passed)' : `FAIL in [${failed}]`}${caught ? '' : `, but not in each of [${rv.checks}]`}`);
    for (const t of runs) {
      const line = t.text.split('\n').find((l) => l.startsWith('FAIL '));
      if (line) console.log(`  first: ${line.slice(0, 200)}`);
    }
    if (!caught) bad = true;
  } finally {
    for (const [f, text] of saved) writeFileSync(root + f, text);
  }
}
if (built) {
  const final = sh('bash', ['bench/build.sh']);
  console.log(`clean build again: ${final.status === 0 ? 'ok' : 'FAILED'}`);
  if (final.status !== 0) bad = true;
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
