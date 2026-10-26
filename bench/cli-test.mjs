// Step 8h wave B issue 5: the command `roc-cloudflare-workers` (js/cli.mjs: sync, sync --check, --force). Node only.
// `init` is not in js/cli.mjs any more (research/talon-fit/TRANSITION.md step 2): the helper `roc-cfw init` has it.
// node bench/cli-test.mjs [dir with app_b3.wasm]    (default: bench/out)
// The app is bench/app_b3.roc: the class Counter, the bindings DB (d1), KV (kv), COUNTERS (object, class Counter), the cron
// "*/5 * * * *", no scheduled!. Each case is a project dir (app.wasm, a Wrangler config of toml or jsonc) and a run of the command.
import { spawnSync } from 'node:child_process';
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const wasm = resolve(process.argv[2] ?? join(root, 'bench/out'), 'app_b3.wasm');
const cli = join(root, 'js/cli.mjs');
const MARK = '// Made by roc-cloudflare-workers sync';
const tmp = mkdtempSync(join(tmpdir(), 'cli-test-'));
process.on('exit', () => rmSync(tmp, { recursive: true, force: true }));
let failed = false;
let n = 0;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const check = (name, cond, why) => (cond ? pass(name) : fail(`${name}: ${why}`));

// ---- A complete config as data, and its two text forms ----

const complete = () => ({
  name: 'b3',
  main: 'worker.js',
  compatibility_date: '2026-10-01',
  compatibility_flags: ['enable_request_signal', 'global_fetch_strictly_public'],
  d1_databases: [{ binding: 'DB', database_name: 'db', database_id: 'x' }],
  kv_namespaces: [{ binding: 'KV', id: 'x' }],
  durable_objects: { bindings: [{ name: 'COUNTERS', class_name: 'Counter' }] },
  migrations: [{ tag: 'v1', new_sqlite_classes: ['Counter'] }],
  triggers: { crons: ['*/5 * * * *'] },
});

const isTable = (v) => v && typeof v === 'object' && !Array.isArray(v);
const isTables = (v) => Array.isArray(v) && v.length > 0 && v.every(isTable);
function toml(o, path = []) {
  const plain = Object.entries(o).filter(([, v]) => !isTable(v) && !isTables(v));
  let out = plain.map(([k, v]) => `${k} = ${JSON.stringify(v)}\n`).join('');
  for (const [k, v] of Object.entries(o)) {
    if (isTable(v)) out += `\n[${[...path, k].join('.')}]\n${toml(v, [...path, k])}`;
    else if (isTables(v)) for (const t of v) out += `\n[[${[...path, k].join('.')}]]\n${toml(t, [...path, k])}`;
  }
  return out;
}
// jsonc: comments and trailing commas, which the command must read.
const jsonc = (o) => `// a Wrangler config\n${JSON.stringify(o, null, 2).replace(/\n}$/, ',\n /* end */ }')}\n`.replace(/"name": "b3",/, '"name": "b3", // the Worker');

// A project dir with app.wasm and the config. `form`: 'toml' or 'jsonc'.
let k = 0;
function project(cfg, form, extra = {}) {
  const dir = join(tmp, `p${k++}`);
  rmSync(dir, { recursive: true, force: true });
  mkdirp(dir);
  copyFileSync(wasm, join(dir, 'app.wasm'));
  writeFileSync(join(dir, form === 'toml' ? 'wrangler.toml' : 'wrangler.jsonc'), form === 'toml' ? toml(cfg) : jsonc(cfg));
  for (const [f, text] of Object.entries(extra)) writeFileSync(join(dir, f), text);
  return dir;
}
const mkdirp = (d) => spawnSync('mkdir', ['-p', d]);
const run = (dir, ...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { cwd: dir, encoding: 'utf8' });
  return { code: r.status, out: r.stdout, err: r.stderr, all: r.stdout + r.stderr };
};

// ---- 1. A complete config: exit 0, worker.js written, --check then exit 0 ----
for (const form of ['toml', 'jsonc']) {
  const dir = project(complete(), form);
  const r = run(dir, 'sync');
  check(`1a ${form}: a complete config gives exit 0`, r.code === 0, `exit ${r.code}: ${r.all}`);
  check(`1b ${form}: no missing and no wrong item`, !/^ {2}(missing|wrong)/m.test(r.out), r.out);
  const w = existsSync(join(dir, 'worker.js')) ? readFileSync(join(dir, 'worker.js'), 'utf8') : '';
  check(`1c ${form}: worker.js has the mark, the class line, the import of app.wasm and makeHandler`, w.startsWith(MARK) && w.includes("export const Counter = objectClass('Counter');") && w.includes("import app from './app.wasm';") && w.includes('export default makeHandler(app);') && /^import \{ makeHandler, objectClass \} from '\.{1,2}\/[^']*\/index\.js';$/m.test(w), w);
  check(`1d ${form}: the bindings and the cron are ok in the output`, ['[[d1_databases]] DB (d1)', '[[kv_namespaces]] KV (kv)', '[[durable_objects.bindings]] COUNTERS (object)', 'triggers.crons has "*/5 * * * *"'].every((s) => r.out.includes(`ok      ${s}`)), r.out);
  const c = run(dir, 'sync', '--check');
  check(`1e ${form}: sync --check after sync gives exit 0`, c.code === 0, `exit ${c.code}: ${c.all}`);
}

// ---- 2. Each missing part: the part is printed, exit 1 ----
// name, change of the config, the text that the output has (a line of the check, and the part to add when it has one).
const cases = [
  ['migrations with new_classes (KV-backed) instead of new_sqlite_classes', (c) => (c.migrations = [{ tag: 'v1', new_classes: ['Counter'] }]), [/wrong +migrations: Counter is in new_classes \(KV-backed\)/]],
  ['no migrations', (c) => delete c.migrations, [/missing +migrations: no new_sqlite_classes for Counter/, /new_sqlite_classes = \["Counter"\]/]],
  ['a missing d1 binding', (c) => delete c.d1_databases, [/missing +\[\[d1_databases\]\] DB \(d1\): not in the config/, /\[\[d1_databases\]\]\nbinding = "DB"/]],
  ['the binding DB under another kind (kv)', (c) => (delete c.d1_databases, c.kv_namespaces.push({ binding: 'DB', id: 'y' })), [/missing +\[\[d1_databases\]\] DB \(d1\): not in the config \(the config has DB as kv\)/]],
  ['a missing cron', (c) => delete c.triggers, [/missing +triggers\.crons has no "\*\/5 \* \* \* \*"/, /\[triggers\]\ncrons = \["\*\/5 \* \* \* \*"\]/]],
  ['a missing flag', (c) => (c.compatibility_flags = ['global_fetch_strictly_public']), [/missing +compatibility_flags has no enable_request_signal/, /compatibility_flags = \["global_fetch_strictly_public","enable_request_signal"\]/]],
  ['a missing object namespace', (c) => delete c.durable_objects, [/missing +\[\[durable_objects\.bindings\]\] COUNTERS \(object\)/, /class_name = "Counter"/]],
  ['a namespace with another class_name', (c) => (c.durable_objects.bindings[0].class_name = 'Other'), [/wrong +\[\[durable_objects\.bindings\]\] COUNTERS \(object\): class_name is "Other", the app has "Counter"/]],
  ['a cron in the config with no handler and no scheduled!', (c) => c.triggers.crons.push('0 0 * * *'), [/wrong +triggers\.crons "0 0 \* \* \*" has no handler/]],
  ['a missing kv binding', (c) => delete c.kv_namespaces, [/missing +\[\[kv_namespaces\]\] KV \(kv\): not in the config/]],
];
for (const form of ['toml', 'jsonc']) {
  for (const [name, change, wants] of cases) {
    const cfg = complete();
    change(cfg);
    const dir = project(cfg, form);
    const r = run(dir, 'sync');
    const miss = wants.filter((re) => !re.test(r.out));
    check(`2 ${form}: ${name}: exit 1 and the part is printed`, r.code === 1 && miss.length === 0, `exit ${r.code}, missing in the output: ${miss.join(' ')}\n${r.all}`);
    const c = run(dir, 'sync', '--check');
    check(`2 ${form}: ${name}: --check gives exit 1 too`, c.code === 1, `exit ${c.code}`);
  }
}

// ---- 3. A bad command line, a bad config, no app: exit 2 ----
{
  const dir = project(complete(), 'toml');
  const bad = [
    ['no command', []],
    ['an unknown command', ['frobnicate']],
    ['an unknown option', ['sync', '--bogus']],
    ['an argument that sync does not take', ['sync', 'extra']],
    ['an option with no value', ['sync', '--wasm']],
    ['a wasm that is not there', ['sync', '--wasm', 'none.wasm']],
    ['init (moved to the helper)', ['init']],
  ];
  for (const [name, args] of bad) {
    const r = run(dir, ...args);
    check(`3 ${name}: exit 2 and the usage`, r.code === 2 && r.err.includes('usage:'), `exit ${r.code}: ${r.all.slice(0, 200)}`);
  }
  const broken = project(complete(), 'toml', { 'wrangler.toml': 'name = \n' });
  const r = run(broken, 'sync');
  check('3 a config that is not TOML: exit 2', r.code === 2, `exit ${r.code}: ${r.all.slice(0, 200)}`);
  const none = project(complete(), 'toml');
  rmSync(join(none, 'wrangler.toml'));
  const r2 = run(none, 'sync');
  check('3 no Wrangler config: exit 1 with the file names', r2.code === 1 && r2.out.includes('no Wrangler config'), `exit ${r2.code}: ${r2.all.slice(0, 200)}`);
}

// ---- 4. worker.js: the mark, --force, --check ----
{
  const own = '// my own entry\nexport default {};\n';
  const dir = project(complete(), 'toml', { 'worker.js': own });
  const r = run(dir, 'sync');
  check('4a a worker.js with no mark is not overwritten: exit 1 and the lines are printed', r.code === 1 && readFileSync(join(dir, 'worker.js'), 'utf8') === own && r.out.includes('not written') && r.out.includes("objectClass('Counter')"), `exit ${r.code}, file ${JSON.stringify(readFileSync(join(dir, 'worker.js'), 'utf8'))}\n${r.out}`);
  const f = run(dir, 'sync', '--force');
  const w = readFileSync(join(dir, 'worker.js'), 'utf8');
  check('4b --force writes it (exit 0, the mark)', f.code === 0 && w.startsWith(MARK), `exit ${f.code}: ${w.slice(0, 80)}`);
  const stale = project(complete(), 'toml', { 'worker.js': `${MARK} (an old file)\nexport default {};\n` });
  const s = run(stale, 'sync');
  check('4c a worker.js with the mark and old content is rewritten', s.code === 0 && readFileSync(join(stale, 'worker.js'), 'utf8').includes("objectClass('Counter')"), `exit ${s.code}`);
  const chk = project(complete(), 'toml', { 'worker.js': `${MARK} (an old file)\nexport default {};\n` });
  const before = readFileSync(join(chk, 'worker.js'), 'utf8');
  const c = run(chk, 'sync', '--check');
  check('4d --check with an old worker.js: exit 1, the file is not changed', c.code === 1 && readFileSync(join(chk, 'worker.js'), 'utf8') === before, `exit ${c.code}`);
  const none = project(complete(), 'toml');
  const c2 = run(none, 'sync', '--check');
  check('4e --check with no worker.js: exit 1, no file is written', c2.code === 1 && !existsSync(join(none, 'worker.js')), `exit ${c2.code}`);
  const cfg = project(complete(), 'toml');
  rmSync(join(cfg, 'wrangler.toml'));
  writeFileSync(join(cfg, 'other.toml'), toml(complete()));
  const o = run(cfg, 'sync', '--config', 'other.toml');
  check('4f --config names the file', o.code === 0 && o.out.includes('other.toml:'), `exit ${o.code}: ${o.out.slice(0, 200)}`);
}

// ---- 5. The import of the shim in worker.js (TRANSITION step 2): R-I1 ----
// R-I1: the relative path from worker.js to the directory of cli.mjs. There is no npm package: no other form.
{
  const shimLine = (dir) => (readFileSync(join(dir, 'worker.js'), 'utf8').match(/^import \{[^}]*\} from '([^']*)';$/m) ?? [])[1];
  const jsDir = join(root, 'js');
  const a = project(complete(), 'toml');
  cpSync(jsDir, join(a, '.roc-cfw'), { recursive: true });
  const ra = spawnSync(process.execPath, [join(a, '.roc-cfw/cli.mjs'), 'sync'], { cwd: a, encoding: 'utf8' });
  check('5a (R-I1) cli.mjs in .roc-cfw/: the import is ./.roc-cfw/index.js', ra.status === 0 && shimLine(a) === './.roc-cfw/index.js', `exit ${ra.status}, import ${shimLine(a)}: ${ra.stdout.slice(0, 200)}`);
  const ca = spawnSync(process.execPath, [join(a, '.roc-cfw/cli.mjs'), 'sync', '--check'], { cwd: a, encoding: 'utf8' });
  check('5a2 (R-I1) sync --check after sync gives exit 0', ca.status === 0, `exit ${ca.status}: ${ca.stdout.slice(0, 200)}`);
  // A worker.js in a subdirectory (--entry): the relative path goes up.
  const c = project(complete(), 'toml');
  cpSync(jsDir, join(c, '.roc-cfw'), { recursive: true });
  mkdirp(join(c, 'sub'));
  const rc = spawnSync(process.execPath, [join(c, '.roc-cfw/cli.mjs'), 'sync', '--entry', 'sub/worker.js'], { cwd: c, encoding: 'utf8' });
  const sub = readFileSync(join(c, 'sub/worker.js'), 'utf8');
  check('5c (R-I1) an entry file in sub/: the import is ../.roc-cfw/index.js', sub.includes("from '../.roc-cfw/index.js';"), `exit ${rc.status}: ${sub.slice(0, 300)}`);
}

// ---- 6. A handler that the app defines and Worker.new does not list (V8): a warning, exit 0; --check exit 1 ----
// The source is a fixture `main.roc` next to app.wasm (app_b3.wasm: the default export has `fetch` only, the class Counter
// has no handler). The scan is lexical: a name at column 0, `name! =` or `name! :`, not in a comment or a string.
const SCHED = 'scheduled! : Worker.Scheduled => Try({}, _)\nscheduled! = |_s| Ok({})\n';
const warn = (line, text) => `sync: main.roc:${line}: ${text}; it never runs`;
{
  const head = 'app [event!] { pf: platform "x" }\n\nimport pf.Worker\n\nfetch! = |_req| Ok(1)\n\n';
  const dir = project(complete(), 'toml', { 'main.roc': `${head}${SCHED}\nworker = Worker.new({ fetch!: fetch! })\n` });
  const r = run(dir, 'sync');
  check('6a (R-V8-1) a scheduled! that Worker.new does not list: one warning with file and line, exit 0', r.code === 0 && r.out.split('\n').filter((l) => l.startsWith('sync:')).join('|') === warn(7, 'scheduled! is defined but Worker.new does not list it'), `exit ${r.code}\n${r.all}`);
  const c = run(dir, 'sync', '--check');
  check('6b (R-V8-2) --check with the same source: the warning and exit 1 (worker.js is up to date)', c.code === 1 && c.out.includes(warn(7, 'scheduled! is defined but Worker.new does not list it')) && c.out.includes('worker.js: up to date'), `exit ${c.code}\n${c.all}`);
  const lines = (src, ...a) => run(project(complete(), 'toml', { 'main.roc': src }), 'sync', ...a).out.split('\n').filter((l) => l.startsWith('sync:'));
  check('6c (R-V8-3) the listed fetch! has no warning', lines(`${head}worker = Worker.new({ fetch!: fetch! })\n`).length === 0, '');
  check('6d (R-V8-4) a def in a comment, in a string and in a multi-line string has no warning', lines(`${head}# scheduled! = |_s| Ok({})\n#queue! : X\ns = "\nemail! = 1\n"\nt = "a \${x} tail! = 2"\nm =\n\\\\ other! = 3\n\\\\ alarm! = 4\n`).length === 0, '');
  const mention = lines(`${head}${SCHED}# the scheduled! handler\nx = "scheduled!"\n`);
  check('6d2 (R-V8-4) the name in a comment or in a string is not a use of the def: the warning stays', mention.join('\n') === warn(7, 'scheduled! is defined but Worker.new does not list it'), mention.join('\n'));
  check('6d3 (R-V8-4) the name in a string interpolation is code, so it is a use', lines(`${head}${SCHED}y = "\${scheduled!}"\n`).length === 0, '');
  check('6e (R-V8-5) a scheduled! that the code uses (Worker.cron) has no warning', lines(`${head}${SCHED}\nworker = Worker.new({ fetch!: fetch!, crons: [Worker.cron("*/5 * * * *", scheduled!)] })\n`).length === 0, '');
  check('6f (R-V8-5) a handler under another name (a field label) has no warning', lines(`${head}handle! = |_req| Ok(1)\nworker = Worker.new({ fetch!: handle!, scheduled!: handle! })\n`).length === 0, '');
  check('6g (R-V8-6) a def inside brackets or indented, and Mod.scheduled!, have no warning', lines(`${head}x = {\nscheduled! = 1\n}\nf = |a| {\n\tqueue! = 2\n\ta\n}\ny = Jobs.email!\n  tail! = 1\n`).length === 0, '');
  const many = lines(`${head}queue! = |_b| Ok({})\nwork = 1\nother! : Str, Js => Try(Js, _)\nother! = |_k, p| Ok(p)\nalarm! = |_s, _i| Ok({})\nweb_socket_message! = |_a| Ok({})\nfetch! : X\n`);
  check('6h (R-V8-7) queue!, other!, alarm! and web_socket_message! that are not listed: one warning each, in line order', many.join('\n') === [warn(7, 'queue! is defined but Worker.new does not list it'), warn(9, 'other! is defined but Worker.new does not list it'), warn(11, 'alarm! is defined but no Object.class lists it'), warn(12, 'web_socket_message! is defined but no Object.class lists it')].join('\n'), many.join('\n'));
  const label = lines(`${head}alarm! = |_s, _i| Ok({})\nc = Object.class("C", { alarm!: other_alarm! })\nd = Mod.alarm!\n`);
  check('6i (R-V8-5) a record label and Mod.alarm! are not a use of the top-level alarm!: the warning stays', label.join('\n') === warn(7, 'alarm! is defined but no Object.class lists it'), label.join('\n'));
  // A source that is not main.roc: --file, or <wasm name>.roc next to the wasm file.
  const f = project(complete(), 'toml', { 'web.roc': SCHED });
  const rf = run(f, 'sync', '--file', 'web.roc');
  check('6j (R-V8-8) --file names the source', rf.code === 0 && rf.out.includes('sync: web.roc:1: scheduled! is defined'), rf.all);
  const rn = run(f, 'sync', '--file', 'none.roc');
  check('6k (R-V8-8) --file with a file that is not there: exit 2', rn.code === 2, `exit ${rn.code}`);
  writeFileSync(join(f, 'app.roc'), SCHED);
  check('6l (R-V8-8) with no --file the source is app.roc next to app.wasm', run(f, 'sync').out.includes('sync: app.roc:1: scheduled! is defined'), '');
  const none = project(complete(), 'toml');
  check('6m no source file: no warning, exit 0', run(none, 'sync').code === 0, '');
}
// The real sources: the apps of the bench and the conformance app list all their handlers. app_events.wasm must be built from
// the platform of this tree (its `other!` is in the manifest since the V8 change): run bench/build.sh when 6o fails.
for (const [name, wasmName, src] of [['6n the conformance app (all kinds, classes and entry points)', 'conformance', 'conformance/app.roc'], ['6o app_events (fetch!, scheduled!, queue!, other!)', 'app_events', 'bench/app_events.roc'], ['6p app_b3', 'app_b3', 'bench/app_b3.roc'], ['6q app_link_callee', 'app_link_callee', 'bench/app_link_callee.roc']]) {
  const dir = project(complete(), 'toml');
  copyFileSync(resolve(wasm, '..', `${wasmName}.wasm`), join(dir, 'app.wasm'));
  const r = run(dir, 'sync', '--file', join(root, src));
  check(`${name}: no warning`, !r.out.includes('sync: ') && !r.err, r.all);
}

// ---- 7. The options file (V21): worker.options.js next to worker.js is the second argument of makeHandler ----
{
  const OPTS = "export default { other: ['ping'] };\n";
  const shim = (dir) => `${relative(dir, join(root, 'js')).split('\\').join('/')}/index.js`;
  const golden = (dir, opts) => `${MARK} from the manifest of the app. Run it again after a change of the classes in Roc.\nimport app from './app.wasm';\nimport { makeHandler, objectClass } from '${shim(dir)}';\n${opts ? "import options from './worker.options.js';\n" : ''}\nexport const Counter = objectClass('Counter');\n\nexport default makeHandler(app${opts ? ', options' : ''});\n`;
  const text = (dir, f) => readFileSync(join(dir, f), 'utf8');
  const none = project(complete(), 'toml');
  const rn = run(none, 'sync');
  check('7a (R-V21-1) no options file: worker.js is the same as before, byte for byte', rn.code === 0 && text(none, 'worker.js') === golden(none, false), text(none, 'worker.js'));
  const dir = project(complete(), 'toml', { 'worker.options.js': OPTS });
  const r = run(dir, 'sync');
  check('7b (R-V21-2) an options file: worker.js imports its default export and passes it to makeHandler', r.code === 0 && text(dir, 'worker.js') === golden(dir, true), `exit ${r.code}\n${text(dir, 'worker.js')}\n${r.all}`);
  check('7c (R-V21-3) sync never writes the options file', text(dir, 'worker.options.js') === OPTS, '');
  const c = run(dir, 'sync', '--check');
  check('7d (R-V21-4) sync --check passes with the import', c.code === 0 && c.out.includes('worker.js: up to date'), `exit ${c.code}\n${c.all}`);
  // The options file is added after worker.js was written (or removed): --check finds the import missing (or extra).
  writeFileSync(join(none, 'worker.options.js'), OPTS);
  const a = run(none, 'sync', '--check');
  check('7e (R-V21-4) --check: an options file and a worker.js with no import gives exit 1', a.code === 1 && a.out.includes('not the file that sync writes') && a.out.includes("import options from './worker.options.js';"), `exit ${a.code}\n${a.out}`);
  rmSync(join(dir, 'worker.options.js'));
  const b = run(dir, 'sync', '--check');
  check('7f (R-V21-4) --check: worker.js has the import and the options file is gone: exit 1', b.code === 1, `exit ${b.code}`);
  check('7g sync writes the file with no import again', run(dir, 'sync').code === 0 && text(dir, 'worker.js') === golden(dir, false), '');
  // The name of the options file follows the name of the entry file (also in a subdirectory). The config has main = worker.js,
  // so these runs exit 1 for the config: only the files are checked.
  const e = project(complete(), 'toml', { 'worker-ledger.options.js': OPTS, 'worker.options.js': 'throw new Error("not this file");' });
  mkdirp(join(e, 'sub'));
  writeFileSync(join(e, 'sub/w.options.js'), OPTS);
  run(e, 'sync', '--entry', 'worker-ledger.js');
  run(e, 'sync', '--entry', 'sub/w.js');
  check('7h (R-V21-5) the options file of worker-ledger.js is worker-ledger.options.js, of sub/w.js it is sub/w.options.js', text(e, 'worker-ledger.js').includes("import options from './worker-ledger.options.js';") && text(e, 'sub/w.js').includes("import options from './w.options.js';"), `${text(e, 'worker-ledger.js')}\n${text(e, 'sub/w.js')}`);
  // An options file with no default export: the entry file would not bundle. Exit 1 and a message.
  const bad = project(complete(), 'toml', { 'worker.options.js': 'export const opts = {};\n' });
  const rb = run(bad, 'sync');
  check('7i (R-V21-6) an options file with no default export: exit 1 and a message', rb.code === 1 && rb.out.includes('worker.options.js: has no default export'), `exit ${rb.code}\n${rb.out}`);
  // A worker.js that sync did not make is still not overwritten (the options file does not change this).
  const own = '// my own entry\nexport default {};\n';
  const h = project(complete(), 'toml', { 'worker.js': own, 'worker.options.js': OPTS });
  const rh = run(h, 'sync');
  check('7j a hand-written worker.js with an options file is still not overwritten', rh.code === 1 && text(h, 'worker.js') === own && rh.out.includes("import options from './worker.options.js';"), `exit ${rh.code}\n${rh.out}`);

  // The Worker loads the options: the worker.js that sync wrote runs in Node. Two lines change: workerd resolves the .wasm
  // import and Node does not, and the shim comes through bench/cf-node.mjs (the stand-in of `cloudflare:workers`). A child
  // process: objectClass registers a name for the process.
  const load = (d) => {
    const w = text(d, 'worker.js')
      .replace("import app from './app.wasm';", `import { readFileSync } from 'node:fs';\nconst app = new WebAssembly.Module(readFileSync(${JSON.stringify(join(d, 'app.wasm'))}));`)
      .replace(/from '[^']*\/index\.js';/, `from ${JSON.stringify(pathToFileURL(join(root, 'bench/cf-node.mjs')).href)};`)
      .replace('export default makeHandler', 'const Handler = makeHandler');
    writeFileSync(join(d, 'worker.test.mjs'), `${w}\nconsole.log('ping:' + typeof Handler.prototype.ping);\n`);
    writeFileSync(join(d, 'package.json'), '{ "type": "module" }');
    return spawnSync(process.execPath, [join(d, 'worker.test.mjs')], { cwd: d, encoding: 'utf8' });
  };
  const withOpts = project(complete(), 'toml', { 'worker.options.js': OPTS });
  run(withOpts, 'sync');
  const lo = load(withOpts);
  check('7k (R-V21-7) the Worker loads the options: other: ["ping"] gives a ping method', lo.status === 0 && lo.stdout.trim() === 'ping:function', `exit ${lo.status}\n${lo.stdout}${lo.stderr.slice(0, 400)}`);
  const noOpts = project(complete(), 'toml');
  run(noOpts, 'sync');
  const ln = load(noOpts);
  check('7l (R-V21-7) with no options file the same Worker has no ping method', ln.status === 0 && ln.stdout.trim() === 'ping:undefined', `exit ${ln.status}\n${ln.stdout}${ln.stderr.slice(0, 400)}`);
  const badOpts = project(complete(), 'toml', { 'worker.options.js': 'export default { bogus: 1 };\n' });
  run(badOpts, 'sync');
  const lb = load(badOpts);
  check('7m (R-V21-7) a bad option name in the options file is a load error of makeHandler', lb.status !== 0 && /unknown option "bogus"/.test(lb.stderr), `exit ${lb.status}\n${lb.stderr.slice(0, 400)}`);
}

console.log(failed ? 'FAILED' : 'all passed');
process.exit(failed ? 1 : 0);
