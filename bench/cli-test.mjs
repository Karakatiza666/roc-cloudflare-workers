// Step 8h wave B issue 5: the command `roc-cloudflare-workers` (js/cli.mjs: sync, sync --check, --force, init). Node only.
// node bench/cli-test.mjs [dir with app_b3.wasm]    (default: bench/out)
// The app is bench/app_b3.roc: the class Counter, the bindings DB (d1), KV (kv), COUNTERS (object, class Counter), the cron
// "*/5 * * * *", no scheduled!. Each case is a project dir (app.wasm, a Wrangler config of toml or jsonc) and a run of the command.
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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
  check(`1c ${form}: worker.js has the mark, the class line, the import of app.wasm and makeHandler`, w.startsWith(MARK) && w.includes("export const Counter = objectClass('Counter');") && w.includes("import app from './app.wasm';") && w.includes('export default makeHandler(app);') && w.includes("import { makeHandler, objectClass } from 'roc-cloudflare-workers';"), w);
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
    ['init with two directories', ['init', 'a', 'b']],
    ['init with a bad name', ['init', 'x', '--name', 'Bad Name']],
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

// ---- 5. init writes the four files, and no file over another ----
{
  const dir = join(tmp, 'new-app');
  const r = run(tmp, 'init', 'new-app', '--platform', 'https://example.com/p.tar.zst');
  const files = ['app.roc', 'worker.js', 'wrangler.toml', 'package.json'];
  check('5a init writes the four files', r.code === 0 && files.every((f) => existsSync(join(dir, f))), `exit ${r.code}: ${r.all.slice(0, 300)}`);
  const app = readFileSync(join(dir, 'app.roc'), 'utf8');
  check('5b app.roc has the platform URL', app.includes('platform "https://example.com/p.tar.zst"'), app.split('\n')[0]);
  check('5c wrangler.toml and package.json have the name of the directory', /^name = "new-app"$/m.test(readFileSync(join(dir, 'wrangler.toml'), 'utf8')) && JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).name === 'new-app', '');
  const again = run(tmp, 'init', 'new-app');
  check('5d init over the files: exit 1 and nothing written', again.code === 1 && again.err.includes('already'), `exit ${again.code}: ${again.all.slice(0, 200)}`);
  writeFileSync(join(dir, 'app.roc'), 'mine');
  const forced = run(tmp, 'init', 'new-app', '--force', '--name', 'other-name');
  check('5e init --force writes over them, with --name', forced.code === 0 && readFileSync(join(dir, 'app.roc'), 'utf8') !== 'mine' && /^name = "other-name"$/m.test(readFileSync(join(dir, 'wrangler.toml'), 'utf8')), `exit ${forced.code}`);
}

console.log(failed ? 'FAILED' : 'all passed');
process.exit(failed ? 1 : 0);
