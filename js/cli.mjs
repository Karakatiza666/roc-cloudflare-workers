#!/usr/bin/env node
// The command of the shim package (README.md "Use it", MODULES.md 3). `.mjs`: the shim runs in workerd, this file only
// in Node, so the module lists of the tests (`*.js`) do not take it.
//   roc-cloudflare-workers sync   reads the manifest of app.wasm, writes worker.js, checks the Wrangler config
//   roc-cloudflare-workers init   writes the four files of a new project (the template is examples/hello)
import { readFileSync, writeFileSync, existsSync, mkdirSync, realpathSync } from 'node:fs';
import { dirname, join, relative, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { manifestOf, NOT_STACK_FIRST } from './runner.js';
import { manifestEvent } from './events.js';
import { checkManifest } from './manifest.js';
import { BINDING_KINDS, tomlOf } from './bindings.js';

const here = dirname(fileURLToPath(import.meta.url));
const MARK = '// Made by roc-cloudflare-workers sync';
// The flags of README.md "Use it": `need` fails the check, the other one is a note.
const FLAGS = [
  { flag: 'enable_request_signal', need: true, why: 'without it request.signal never fires, so a task does not stop when the client goes away' },
  { flag: 'global_fetch_strictly_public', need: false, why: 'without it a fetch of another Worker of your account on workers.dev gives 404 error code 1042 on the edge; drop it if the app never fetches such a URL' },
];
const MIN_DATE = '2026-10-01';

const USAGE = `usage:
  roc-cloudflare-workers sync [--wasm app.wasm] [--entry worker.js] [--config wrangler.toml] [--check] [--force]
      Reads the manifest of the app (Worker.new), writes the entry file (the objectClass and entrypointClass lines and
      makeHandler), and checks the Wrangler config: the Durable Object bindings and migrations, the bindings of
      Worker.new bindings, triggers.crons of Worker.new crons, and the compatibility flags. It prints the parts to add.
      --check: write nothing, fail when the entry file is not the one that sync writes.
      --force: write the entry file also when it was not made by sync.
      Exit 0: all good. Exit 1: a part is missing or wrong. Exit 2: a bad command line or no app.
  roc-cloudflare-workers init [dir] [--name NAME] [--platform URL] [--force]
      Writes app.roc, worker.js, wrangler.toml and package.json of a new project (from examples/hello).`;

// ---- The command line ----

function parseArgs(argv, flags, values) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (flags.includes(a)) out[a.slice(2)] = true;
    else if (values.includes(a)) {
      if (i + 1 >= argv.length) usage(`${a} needs a value`);
      out[a.slice(2)] = argv[++i];
    } else if (a.startsWith('--')) usage(`unknown option ${a}`);
    else out._.push(a);
  }
  return out;
}

function usage(msg) {
  if (msg) console.error(`roc-cloudflare-workers: ${msg}`);
  console.error(USAGE);
  process.exit(2);
}

// ---- The Wrangler config ----

// A TOML reader for the parts of a Wrangler config: tables, arrays of tables, dotted keys, strings, numbers, booleans,
// arrays and inline tables. A date or another bare value is kept as text.
export function parseToml(text, file = 'wrangler.toml') {
  const root = {};
  let cur = root;
  let i = 0;
  const n = text.length;
  const err = (what) => {
    throw new Error(`${file} line ${text.slice(0, i).split('\n').length}: ${what} expected`);
  };
  const ws = () => {
    while (i < n && (text[i] === ' ' || text[i] === '\t')) i++;
  };
  const comment = () => {
    if (text[i] === '#') while (i < n && text[i] !== '\n') i++;
  };
  const wsnl = () => {
    for (;;) {
      ws();
      comment();
      if (text[i] === '\n' || text[i] === '\r') i++;
      else return;
    }
  };
  const ESC = { b: '\b', t: '\t', n: '\n', f: '\f', r: '\r', '"': '"', '\\': '\\' };
  const str = () => {
    const d3 = text.slice(i, i + 3);
    if (d3 === '"""' || d3 === "'''") {
      i += 3;
      if (text[i] === '\n') i++;
      const end = text.indexOf(d3, i);
      if (end < 0) err(`the end ${d3} of a string`);
      const s = text.slice(i, end);
      i = end + 3;
      return s;
    }
    const d = text[i++];
    let s = '';
    while (i < n && text[i] !== d) {
      if (text[i] === '\n') err(`the end ${d} of a string`);
      if (d === '"' && text[i] === '\\') {
        const c = text[i + 1];
        if (c === 'u' || c === 'U') {
          const len = c === 'u' ? 4 : 8;
          s += String.fromCodePoint(parseInt(text.slice(i + 2, i + 2 + len), 16));
          i += 2 + len;
        } else {
          if (!(c in ESC)) err('an escape');
          s += ESC[c];
          i += 2;
        }
        continue;
      }
      s += text[i++];
    }
    if (i >= n) err(`the end ${d} of a string`);
    i++;
    return s;
  };
  const key = () => {
    const parts = [];
    for (;;) {
      ws();
      if (text[i] === '"' || text[i] === "'") parts.push(str());
      else {
        const m = /^[A-Za-z0-9_-]+/.exec(text.slice(i, i + 256));
        if (!m) err('a key');
        i += m[0].length;
        parts.push(m[0]);
      }
      ws();
      if (text[i] !== '.') return parts;
      i++;
    }
  };
  // A key twice is an error in TOML, and Wrangler refuses the file.
  const setPath = (o, parts, v) => {
    for (const p of parts.slice(0, -1)) o = o[p] ??= {};
    if (Object.hasOwn(o, parts.at(-1))) err(`a key once (${parts.join('.')} is twice), so`);
    o[parts.at(-1)] = v;
  };
  const value = () => {
    ws();
    const c = text[i];
    if (c === '"' || c === "'") return str();
    if (c === '[') {
      i++;
      const a = [];
      for (;;) {
        wsnl();
        if (text[i] === ']') {
          i++;
          return a;
        }
        a.push(value());
        wsnl();
        if (text[i] === ',') i++;
        else if (text[i] !== ']') err(', or ]');
      }
    }
    if (c === '{') {
      i++;
      const o = {};
      ws();
      if (text[i] === '}') {
        i++;
        return o;
      }
      for (;;) {
        const k = key();
        if (text[i] !== '=') err('=');
        i++;
        setPath(o, k, value());
        ws();
        if (text[i] === ',') i++;
        else if (text[i] === '}') {
          i++;
          return o;
        } else err(', or }');
      }
    }
    const m = /^[^\s,\]}#]+/.exec(text.slice(i, i + 256));
    if (!m) err('a value');
    i += m[0].length;
    if (m[0] === 'true') return true;
    if (m[0] === 'false') return false;
    const num = Number(m[0].replace(/_/g, ''));
    return Number.isNaN(num) ? m[0] : num;
  };
  for (;;) {
    wsnl();
    if (i >= n) return root;
    if (text[i] === '[') {
      const many = text[i + 1] === '[';
      i += many ? 2 : 1;
      const path = key();
      if (many ? !text.startsWith(']]', i) : text[i] !== ']') err(many ? ']]' : ']');
      i += many ? 2 : 1;
      let o = root;
      path.forEach((p, j) => {
        if (j === path.length - 1 && many) {
          if (o[p] !== undefined && !Array.isArray(o[p])) err(`an array of tables for ${path.join('.')}`);
          const t = {};
          (o[p] ??= []).push(t);
          o = t;
        } else {
          const v = (o[p] ??= {});
          o = Array.isArray(v) ? v.at(-1) : v;
        }
      });
      cur = o;
    } else {
      const k = key();
      if (text[i] !== '=') err('=');
      i++;
      setPath(cur, k, value());
    }
    ws();
    comment();
    if (i < n && text[i] !== '\n' && text[i] !== '\r') err('the end of the line');
  }
}

// A wrangler.json or wrangler.jsonc: JSON with comments and trailing commas.
export function parseJsonc(text) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      const start = i;
      for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\') i++;
      out += text.slice(start, i + 1);
    } else if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2) + 1;
      if (i === 0) throw new Error('a comment /* has no end');
    } else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, '$1'));
}

function findConfig(dir, given) {
  if (given) return resolve(given);
  for (const f of ['wrangler.json', 'wrangler.jsonc', 'wrangler.toml']) if (existsSync(join(dir, f))) return join(dir, f);
  return null;
}

function readConfig(file) {
  const text = readFileSync(file, 'utf8');
  return file.endsWith('.toml') ? parseToml(text, basename(file)) : parseJsonc(text);
}

// The tables of one binding kind in the config.
const entriesOf = (cfg, k) => {
  const part = at(cfg, k.section);
  return k.many ? (Array.isArray(part) ? part : []) : part && typeof part === 'object' && part[k.key] ? [part] : [];
};

const at = (o, path) => path.split('.').reduce((v, k) => (v === undefined || v === null ? undefined : v[k]), o);

// ---- sync ----

// The entry file of the manifest: one export line for each class, then the default export.
export function entryOf(m, wasmImport) {
  const objects = Object.keys(m.objects);
  const entrypoints = Object.keys(m.entrypoints);
  const names = ['makeHandler', ...(objects.length ? ['objectClass'] : []), ...(entrypoints.length ? ['entrypointClass'] : [])];
  const lines = [
    `${MARK} from the manifest of the app. Run it again after a change of the classes in Roc.`,
    `import app from '${wasmImport}';`,
    `import { ${names.join(', ')} } from 'roc-cloudflare-workers';`,
    '',
  ];
  for (const c of objects) lines.push(`export const ${c} = objectClass('${c}');`);
  for (const c of entrypoints) lines.push(`export const ${c} = entrypointClass('${c}');`);
  if (objects.length || entrypoints.length) lines.push('');
  lines.push('export default makeHandler(app);', '');
  return lines.join('\n');
}

// The checks of the Wrangler config against the manifest. Each item: `{ level: 'ok' | 'missing' | 'wrong' | 'note',
// text, add? }`. `add`: a config part (TOML text) to add.
export function checkConfig(m, cfg, { entry, scheduled }) {
  const out = [];
  const ok = (text) => out.push({ level: 'ok', text });
  const missing = (text, add) => out.push({ level: 'missing', text, add });
  const wrong = (text) => out.push({ level: 'wrong', text });
  const note = (text, add) => out.push({ level: 'note', text, add });

  // main, the date, the flags.
  if (entry !== undefined) {
    if (cfg.main === undefined) missing(`main: the config has no main`, `main = "${entry}"`);
    else if (cfg.main.replace(/^\.\//, '') !== entry) wrong(`main is "${cfg.main}", and sync writes the entry ${entry}`);
    else ok(`main = "${cfg.main}"`);
  }
  if (typeof cfg.compatibility_date !== 'string') missing('compatibility_date: none', `compatibility_date = "${MIN_DATE}"`);
  else if (cfg.compatibility_date < MIN_DATE) note(`compatibility_date ${cfg.compatibility_date} is older than ${MIN_DATE}, the date of the tests of the platform`);
  else ok(`compatibility_date = "${cfg.compatibility_date}"`);
  const flags = cfg.compatibility_flags ?? [];
  const all = JSON.stringify([...flags, ...FLAGS.map((f) => f.flag).filter((f) => !flags.includes(f))]);
  let given = false;
  for (const f of FLAGS) {
    if (flags.includes(f.flag)) ok(`compatibility_flags has ${f.flag}`);
    else {
      // One config part for all the flags, with the first item that has no flag.
      (f.need ? missing : note)(`compatibility_flags has no ${f.flag}: ${f.why}`, given ? undefined : `compatibility_flags = ${all}`);
      given = true;
    }
  }

  // Durable Object classes: the migrations give the classes of this Worker. The platform needs SQLite-backed classes.
  const sqlite = new Set();
  const kvClasses = new Set();
  for (const mig of cfg.migrations ?? []) {
    for (const c of mig.new_sqlite_classes ?? []) sqlite.add(c);
    for (const c of mig.new_classes ?? []) kvClasses.add(c);
    for (const r of mig.renamed_classes ?? []) {
      for (const s of [sqlite, kvClasses]) if (s.delete(r.from)) s.add(r.to);
    }
    for (const c of mig.deleted_classes ?? []) {
      sqlite.delete(c);
      kvClasses.delete(c);
    }
  }
  const classes = Object.keys(m.objects);
  const newClasses = [];
  for (const c of classes) {
    if (sqlite.has(c)) ok(`migrations: ${c} in new_sqlite_classes`);
    else if (kvClasses.has(c)) wrong(`migrations: ${c} is in new_classes (KV-backed). The platform needs a SQLite-backed class: a new class name in new_sqlite_classes`);
    else newClasses.push(c);
  }
  if (newClasses.length) {
    const tag = `v${(cfg.migrations ?? []).length + 1}`;
    missing(`migrations: no new_sqlite_classes for ${newClasses.join(', ')}`, `[[migrations]]\ntag = "${tag}"\nnew_sqlite_classes = ${JSON.stringify(newClasses)}`);
  }
  for (const c of [...sqlite, ...kvClasses]) if (!classes.includes(c)) wrong(`migrations: the class ${c} has no Object.class("${c}", ...) in the objects of Worker.new (workerd needs an export for it)`);

  // The bindings of Worker.new bindings.
  const declared = new Set();
  for (const b of m.bindings) {
    const k = BINDING_KINDS[b.kind];
    declared.add(`${k.section} ${b.name}`);
    const part = at(cfg, k.section);
    const found = k.many ? (Array.isArray(part) ? part.find((e) => e?.[k.key] === b.name) : undefined) : part?.[k.key] === b.name ? part : undefined;
    const label = `${k.many ? `[[${k.section}]]` : `[${k.section}]`} ${b.name} (${b.kind})`;
    if (!found) {
      const other = Object.entries(BINDING_KINDS).find(([, o]) => entriesOf(cfg, o).some((e) => e?.[o.key] === b.name));
      missing(`${label}: not in the config${other ? ` (the config has ${b.name} as ${other[0]})` : ''}`, tomlOf(b));
      continue;
    }
    const bad = [];
    if (b.kind === 'object') {
      if (found.class_name !== b.class) bad.push(`class_name is ${JSON.stringify(found.class_name)}, the app has ${JSON.stringify(b.class)}`);
      if ((found.script_name ?? '') !== (b.script ?? '')) bad.push(`script_name is ${JSON.stringify(found.script_name ?? '')}, the app has ${JSON.stringify(b.script ?? '')}`);
    }
    if (b.kind === 'service') {
      if (b.service && found.service !== b.service) bad.push(`service is ${JSON.stringify(found.service)}, the app has ${JSON.stringify(b.service)}`);
      if (b.entrypoint && found.entrypoint !== b.entrypoint) bad.push(`entrypoint is ${JSON.stringify(found.entrypoint ?? '')}, the app has ${JSON.stringify(b.entrypoint)}`);
    }
    if (bad.length) wrong(`${label}: ${bad.join('; ')}`);
    else ok(label);
  }
  // Parts of the config that the app does not declare: a note (an app can read env with Js programs).
  for (const [kind, k] of Object.entries(BINDING_KINDS)) {
    for (const e of entriesOf(cfg, k)) {
      const name = e?.[k.key];
      if (typeof name === 'string' && !declared.has(`${k.section} ${name}`)) note(`${k.many ? `[[${k.section}]]` : `[${k.section}]`} ${name}: not in Worker.new bindings (${kind}), so the shim does not check it`);
      if (kind === 'object' && typeof name === 'string' && !e.script_name && !classes.includes(e.class_name)) wrong(`[[durable_objects.bindings]] ${name}: the class ${e.class_name} has no Object.class("${e.class_name}", ...) in the objects of Worker.new`);
    }
  }

  // Crons: each cron of Worker.new crons in triggers.crons. A cron of the config with no handler of its own goes to
  // scheduled!, so it needs one.
  const have = at(cfg, 'triggers.crons') ?? [];
  const need = m.crons.filter((c) => !have.includes(c));
  for (const c of m.crons) if (have.includes(c)) ok(`triggers.crons has "${c}"`);
  if (need.length) missing(`triggers.crons has no ${need.map((c) => `"${c}"`).join(', ')}`, `[triggers]\ncrons = ${JSON.stringify([...have, ...need])}`);
  for (const c of have) {
    if (m.crons.includes(c)) continue;
    if (scheduled) ok(`triggers.crons "${c}" goes to scheduled!`);
    else wrong(`triggers.crons "${c}" has no handler: add Worker.cron("${c}", ...) to the crons of Worker.new, or a scheduled!`);
  }
  return out;
}

function sync(argv) {
  const a = parseArgs(argv, ['--check', '--force'], ['--wasm', '--entry', '--config']);
  if (a._.length) usage(`sync takes no argument ${a._[0]}`);
  const dir = process.cwd();
  const wasm = resolve(a.wasm ?? 'app.wasm');
  const entry = resolve(a.entry ?? 'worker.js');
  if (!existsSync(wasm)) usage(`${relative(dir, wasm)} is not there: build the app first (roc build --target=wasm32 --no-cache --output=app.wasm app.roc)`);
  const got = manifestOf(new WebAssembly.Module(readFileSync(wasm)), manifestEvent());
  if (got === undefined) {
    console.error(`roc-cloudflare-workers: ${relative(dir, wasm)}: ${NOT_STACK_FIRST}`);
    process.exit(2);
  }
  if (got === null) console.log(`${relative(dir, wasm)}: the app has no Worker.new (a raw event!): no classes, bindings or crons to check`);
  const m = checkManifest(got ?? { objects: {}, entrypoints: {} });
  let fail = false;

  // The entry file.
  let wasmImport = relative(dirname(entry), wasm).split('\\').join('/');
  if (!wasmImport.startsWith('.')) wasmImport = `./${wasmImport}`;
  const want = entryOf(m, wasmImport);
  const old = existsSync(entry) ? readFileSync(entry, 'utf8') : null;
  const name = relative(dir, entry);
  const counts = `${Object.keys(m.objects).length} object classes, ${Object.keys(m.entrypoints).length} entry points`;
  if (old === want) console.log(`${name}: up to date (${counts})`);
  else if (a.check) {
    console.log(`${name}: not the file that sync writes (${counts}). Run roc-cloudflare-workers sync. The file:\n${want}`);
    fail = true;
  } else if (old !== null && !old.startsWith(MARK) && !a.force) {
    console.log(`${name}: not written: sync did not make it (no "${MARK}" line). Put these lines in it, or use --force:\n${want}`);
    fail = true;
  } else {
    writeFileSync(entry, want);
    console.log(`${name}: written (${counts})`);
  }

  // The Wrangler config.
  const cfgFile = findConfig(dir, a.config);
  if (!cfgFile || !existsSync(cfgFile)) {
    console.log(`no Wrangler config (wrangler.json, wrangler.jsonc or wrangler.toml) in ${dir}`);
    process.exit(1);
  }
  const cfgName = relative(dir, cfgFile);
  let items;
  try {
    items = checkConfig(m, readConfig(cfgFile), { entry: relative(dirname(cfgFile), entry).split('\\').join('/'), scheduled: m.handlers.includes('scheduled') });
  } catch (e) {
    console.error(`roc-cloudflare-workers: ${e.message}`);
    process.exit(2);
  }
  console.log(`${cfgName}:`);
  for (const it of items) console.log(`  ${it.level.padEnd(7)} ${it.text}`);
  // Two groups: the top-level keys (they go before the first table, and replace a key of the same name) and the
  // tables (at the end). A part of a note is a choice: it is shown as a comment.
  const adds = items.filter((it) => it.add && it.level !== 'ok');
  const show = (it) => (it.level === 'note' ? `# A choice (${it.text.split(':')[0]}):\n${it.add.replace(/^/gm, '# ')}` : it.add);
  const json = cfgFile.endsWith('.toml') ? '' : ' (as JSON)';
  const top = adds.filter((it) => !it.add.startsWith('['));
  const tables = adds.filter((it) => it.add.startsWith('['));
  if (top.length) console.log(`\nSet at the top of ${cfgName}${json}, before the first table (in place of a key of the same name):\n\n${top.map(show).join('\n')}`);
  if (tables.length) console.log(`\nAdd to the end of ${cfgName}${json}:\n\n${tables.map(show).join('\n\n')}`);
  if (items.some((it) => it.level === 'missing' || it.level === 'wrong')) fail = true;
  process.exit(fail ? 1 : 0);
}

// ---- init ----

// The template: `template/` of the package (scripts/bundle.sh copies examples/hello there), or examples/hello of the repo.
function templateDir() {
  for (const d of [join(here, 'template'), join(here, '..', 'examples', 'hello')]) if (existsSync(join(d, 'app.roc'))) return d;
  throw new Error('no template: the package has no template/ directory');
}

// `release.json` (scripts/bundle.sh): the version and the URLs of the release of this package.
function release() {
  try {
    return JSON.parse(readFileSync(join(here, 'release.json'), 'utf8'));
  } catch {
    return null;
  }
}

function init(argv) {
  const a = parseArgs(argv, ['--force'], ['--name', '--platform']);
  if (a._.length > 1) usage('init takes one directory');
  const dir = resolve(a._[0] ?? '.');
  const name = a.name ?? (basename(dir).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '') || 'roc-app');
  if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) usage(`the name ${JSON.stringify(name)} is not a Worker name (a-z, 0-9, -)`);
  const rel = release();
  const platform = a.platform ?? rel?.platform;
  const t = templateDir();
  const files = ['app.roc', 'worker.js', 'wrangler.toml', 'package.json'];
  const there = files.filter((f) => existsSync(join(dir, f)));
  if (there.length && !a.force) {
    console.error(`roc-cloudflare-workers: ${there.join(', ')} in ${dir} already: init writes no file over another (--force does)`);
    process.exit(1);
  }
  const read = (f) => readFileSync(join(t, f), 'utf8');
  const app = read('app.roc')
    .replace(/platform "[^"]*"/, `platform "${platform ?? '<the platform URL of the release>'}"`)
    .replace(/^## The platform line is a path.*\n/m, '');
  const toml = read('wrangler.toml').replace(/^name = ".*"$/m, `name = "${name}"`).replace(/^database_name = ".*"$/m, `database_name = "${name}"`).replace(/wrangler d1 create \S+/g, `wrangler d1 create ${name}`);
  const pkg = JSON.parse(read('package.json'));
  pkg.name = name;
  if (rel?.shim) pkg.dependencies['roc-cloudflare-workers'] = rel.shim;
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'app.roc'), app);
  writeFileSync(join(dir, 'worker.js'), read('worker.js'));
  writeFileSync(join(dir, 'wrangler.toml'), toml);
  writeFileSync(join(dir, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');
  console.log(`wrote ${files.join(', ')} in ${dir}`);
  if (!platform) console.log('app.roc: put the platform URL of the release in the platform line (--platform URL).');
  if (!rel?.shim) console.log('package.json: put the URL of the shim package of the release in dependencies.');
  console.log('Next: npm install, npm run build (roc build, then roc-cloudflare-workers sync), npm run dev.');
}

// ---- main ----

// The command runs only when Node runs this file (also through the `bin` link of npm), not on an import of a test.
const isMain = () => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
};
if (isMain()) {
  const [cmd, ...rest] = process.argv.slice(2);
  try {
    if (cmd === 'sync') sync(rest);
    else if (cmd === 'init') init(rest);
    else usage(cmd ? `unknown command ${cmd}` : undefined);
  } catch (e) {
    console.error(`roc-cloudflare-workers: ${e.message}`);
    process.exit(2);
  }
}
