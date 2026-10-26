#!/usr/bin/env node
// The command of the shim (README.md "Use it", MODULES.md 3). `.mjs`: the shim runs in workerd, this file only
// in Node, so the module lists of the tests (`*.js`) do not take it. There is no npm package: `node js/cli.mjs sync` in
// this repository, `node .roc-cfw/cli.mjs sync` (or `roc-cfw sync`) in a project.
//   node cli.mjs sync   reads the manifest of app.wasm, writes worker.js, checks the Wrangler config
// `init` is not here: it is `roc-cfw init` of the helper, with the files of template/ (research/talon-fit/TRANSITION.md).
import { readFileSync, writeFileSync, existsSync, realpathSync, readdirSync, statSync } from 'node:fs';
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
  node cli.mjs sync [--wasm app.wasm] [--entry worker.js] [--config wrangler.toml] [--file main.roc] [--check] [--force]
      Reads the manifest of the app (Worker.new), writes the entry file (the objectClass and entrypointClass lines and
      makeHandler), and checks the Wrangler config: the Durable Object bindings and migrations, the bindings of
      Worker.new bindings, triggers.crons of Worker.new crons, and the compatibility flags. It prints the parts to add.
      It also reads the app source (--file; default: <wasm name>.roc next to the wasm file, else main.roc) and warns of a
      handler that the source defines at the top level (scheduled!, queue!, alarm!, ...) and that Worker.new, Object.class or
      Rpc.entrypoint does not list: it never runs. A warning is exit 0, and exit 1 with --check.
      An options file next to the entry file (worker.options.js for worker.js) is the second argument of makeHandler: the
      entry file imports its default export. sync never writes the options file.
      It also checks the link to the other Workers of the repo: a service binding (service, entrypoint) and a Durable
      Object binding with script_name go to a Worker whose Wrangler config has that name (found from the repo root, the
      directory with .git). The interface name of the caller (Rpc.iface) must be the one of the entry point or class.
      --check: write nothing, fail when the entry file is not the one that sync writes or a handler is not listed.
      --force: write the entry file also when it was not made by sync.
      The entry file imports the shim by the relative path from the entry file to the directory of this file
      (./.roc-cfw/index.js).
      Exit 0: all good. Exit 1: a part is missing or wrong. Exit 2: a bad command line or no app.`;

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

// The import of the shim in the entry file: the relative path from `entryDir` to `cliDir` (the directory of this file:
// the copy `.roc-cfw/` of a project, or `js/` of this repository).
export function shimImportOf(entryDir, cliDir) {
  const rel = relative(entryDir, cliDir).split('\\').join('/');
  const dir = /^\.\.?(\/|$)/.test(rel) ? rel : `./${rel}`;
  return `${dir.replace(/\/$/, '')}/index.js`;
}

// The name of the options file of an entry file: `worker.js` has `worker.options.js` (MODULES.md 3, "The options file").
export function optionsFileOf(entry) {
  return entry.replace(/\.m?js$/, '') + '.options.js';
}

// The entry file of the manifest: one export line for each class, then the default export. `optionsImport` (the path
// of the options file, `./worker.options.js`) is the second argument of makeHandler; none gives the file with no options.
export function entryOf(m, wasmImport, shimImport, optionsImport = null) {
  const objects = Object.keys(m.objects);
  const entrypoints = Object.keys(m.entrypoints);
  const names = ['makeHandler', ...(objects.length ? ['objectClass'] : []), ...(entrypoints.length ? ['entrypointClass'] : [])];
  const lines = [
    `${MARK} from the manifest of the app. Run it again after a change of the classes in Roc.`,
    `import app from '${wasmImport}';`,
    `import { ${names.join(', ')} } from '${shimImport}';`,
    ...(optionsImport ? [`import options from '${optionsImport}';`] : []),
    '',
  ];
  for (const c of objects) lines.push(`export const ${c} = objectClass('${c}');`);
  for (const c of entrypoints) lines.push(`export const ${c} = entrypointClass('${c}');`);
  if (objects.length || entrypoints.length) lines.push('');
  lines.push(optionsImport ? 'export default makeHandler(app, options);' : 'export default makeHandler(app);', '');
  return lines.join('\n');
}

// ---- The handlers that the app defines and does not list (MODULES.md 3, "A handler that is not listed") ----

// The handlers of the platform by the Roc name: the JS name of the manifest, and where the manifest lists it. `default`:
// the fields of Worker.new. `class`: the fields of Object.class. `fetch`: Worker.new, Object.class or Rpc.entrypoint.
// `other!` is in the `handlers` of the default export since the manifest of this version.
const HANDLER_DEFS = {
  'fetch!': { js: 'fetch', in: 'fetch' },
  'scheduled!': { js: 'scheduled', in: 'default' },
  'queue!': { js: 'queue', in: 'default' },
  'email!': { js: 'email', in: 'default' },
  'tail!': { js: 'tail', in: 'default' },
  'other!': { js: 'other', in: 'default' },
  'init!': { js: 'init', in: 'class' },
  'alarm!': { js: 'alarm', in: 'class' },
  'web_socket_message!': { js: 'webSocketMessage', in: 'class' },
  'web_socket_close!': { js: 'webSocketClose', in: 'class' },
  'web_socket_error!': { js: 'webSocketError', in: 'class' },
};
const WHO_LISTS = { default: 'Worker.new does not list it', class: 'no Object.class lists it', fetch: 'Worker.new, Object.class and Rpc.entrypoint do not list it' };

// A lexical scan of a Roc source: `defs` has each name with `!` that is defined at the top level (at column 0, outside of
// brackets, as `name! =` or `name! :`) with the line of its first definition or annotation. `uses` has each such name that
// the code also has anywhere else (not after a dot: `Routes.fetch!` is another def). A comment, a string (also its
// `${...}` parts, which are code) and a `\\` line of a multi-line string are not code.
export function scanDefs(text) {
  const defs = new Map();
  const uses = new Set();
  const n = text.length;
  const stack = []; // the bracket depth at each open `${` of a string
  let i = 0;
  let line = 1;
  let depth = 0;
  let inString = false;
  let lineStart = true;
  const ident = /[A-Za-z_][A-Za-z0-9_]*!?/y;
  const def = /[ \t]*(?:=(?![=>])|:(?!:))/y;
  const label = /[ \t]*:(?!:)/y;
  while (i < n) {
    const c = text[i];
    if (inString) {
      if (c === '\\') {
        if (text[i + 1] === '\n') line++;
        i += 2;
      } else if (c === '"') {
        inString = false;
        i++;
      } else if (c === '$' && text[i + 1] === '{') {
        stack.push(depth++);
        inString = false;
        i += 2;
      } else {
        if (c === '\n') line++;
        i++;
      }
      continue;
    }
    if (c === '\n') {
      line++;
      lineStart = true;
      i++;
      continue;
    }
    const atStart = lineStart;
    lineStart = false;
    if (c === '#' || (c === '\\' && text[i + 1] === '\\')) {
      while (i < n && text[i] !== '\n') i++;
    } else if (c === '"') {
      inString = true;
      i++;
    } else if (/[A-Za-z_]/.test(c)) {
      ident.lastIndex = i;
      const name = ident.exec(text)[0];
      const dotted = i > 0 && text[i - 1] === '.';
      i += name.length;
      if (name.endsWith('!') && !dotted) {
        def.lastIndex = i;
        if (atStart && depth === 0 && def.test(text)) {
          if (!defs.has(name)) defs.set(name, line);
        } else {
          // A record label (`scheduled!: handle!`) is not a use of the def of that name.
          label.lastIndex = i;
          if (!label.test(text)) uses.add(name);
        }
      }
    } else {
      if (c === '(' || c === '[' || c === '{') depth++;
      else if (c === ')' || c === ']' || c === '}') {
        depth = Math.max(0, depth - 1);
        if (c === '}' && stack.length && stack.at(-1) === depth) {
          stack.pop();
          inString = true;
        }
      }
      i++;
    }
  }
  return { defs, uses };
}

// The handlers that the source defines at the top level and the manifest does not list, and that the code does not use
// in another place (a `Worker.cron("...", scheduled!)` uses it): `[{ name, line, text }]` in the order of the lines.
export function unlistedHandlers(m, source) {
  const { defs, uses } = scanDefs(source);
  const classes = [...Object.values(m.objects), ...Object.values(m.entrypoints)];
  const listed = {
    default: (js) => m.handlers.includes(js),
    class: (js) => classes.some((c) => c.handlers.includes(js)),
    fetch: (js) => m.handlers.includes(js) || classes.some((c) => c.handlers.includes(js)),
  };
  const out = [];
  for (const [name, line] of defs) {
    const h = HANDLER_DEFS[name];
    if (!h || uses.has(name) || listed[h.in](h.js)) continue;
    out.push({ name, line, text: `${name} is defined but ${WHO_LISTS[h.in]}; it never runs` });
  }
  return out.sort((x, y) => x.line - y.line);
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

// ---- The link to the other Workers (MODULES.md 3) ----

// The Wrangler configs of a repo: `wrangler.toml`, `wrangler.json`, `wrangler.jsonc` and `wrangler-<x>.toml` (several
// Workers in one directory). Not in these directories.
const SKIP_DIRS = new Set(['node_modules', '.git', '.cache', '.claude', '.wrangler', '.zig-cache', 'zig-out']);
const CONFIG_NAME = /^wrangler([-.][\w.-]*)?\.(toml|jsonc?)$/;

// The directory with `.git` (a directory, or a file in a submodule or a worktree) at or above `dir`, or `dir`.
export function repoRoot(dir) {
  for (let d = resolve(dir); ; d = dirname(d)) {
    if (existsSync(join(d, '.git'))) return d;
    if (dirname(d) === d) return resolve(dir);
  }
}

// All Wrangler configs below `root` that have a `name`: `[{ file, cfg, name }]`, sorted by path. A file that does not parse
// is not a Worker here.
export function findWorkers(root, depth = 8) {
  const out = [];
  const walk = (d, left) => {
    let list;
    try {
      list = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of list.sort((x, y) => x.name.localeCompare(y.name))) {
      const f = join(d, e.name);
      if (e.isDirectory()) {
        if (left > 0 && !SKIP_DIRS.has(e.name)) walk(f, left - 1);
      } else if (CONFIG_NAME.test(e.name)) {
        try {
          const cfg = readConfig(f);
          if (typeof cfg?.name === 'string') out.push({ file: f, cfg, name: cfg.name });
        } catch {}
      }
    }
  };
  walk(root, depth);
  return out;
}

// The wasm of a Worker: the file that its `main` entry imports (`import app from './ledger.wasm'`), else `app.wasm` next
// to the entry, else `app.wasm` next to the config.
export function wasmOf(w) {
  const dir = dirname(w.file);
  const entry = typeof w.cfg.main === 'string' ? resolve(dir, w.cfg.main) : null;
  if (entry && existsSync(entry)) {
    const m = /(?:from|import)\s*['"]([^'"]+\.wasm)['"]/.exec(readFileSync(entry, 'utf8'));
    if (m) return resolve(dirname(entry), m[1]);
    return join(dirname(entry), 'app.wasm');
  }
  return join(dir, 'app.wasm');
}

// The `.roc` files that the app of a wasm is made from: `<name>.roc` next to it, and the modules that it imports from the same
// directory (`import Gavel`, not `import pf.Rpc`), again for each of them. Empty when there is no `<name>.roc`.
export function sourcesOf(wasm) {
  const dir = dirname(wasm);
  const todo = [join(dir, `${basename(wasm, '.wasm')}.roc`)];
  const seen = new Set();
  while (todo.length) {
    const f = todo.pop();
    if (seen.has(f) || !existsSync(f)) continue;
    seen.add(f);
    for (const m of readFileSync(f, 'utf8').matchAll(/^import\s+([A-Z][\w.]*)/gm)) todo.push(join(dir, `${m[1].replace(/\./g, '/')}.roc`));
  }
  return [...seen];
}

// The checks of the links to other Workers: the service bindings and the Durable Object bindings with `script_name` of
// the config `cfgFile`, against the manifest of the Worker that has the name. Items as in `checkConfig`. Not a failure:
// the target is not found, not built, older than its sources (`note`). A failure (`wrong`): the entry point or the class is
// not in the manifest of the target, or its interface name is not the one of the caller's binding (`Rpc.iface`).
// `manifestFor(wasm)` gives the checked manifest of a wasm, or throws.
export function crossCheck(m, cfg, { cfgFile, wasmFile, root, workers, manifestFor, dir = process.cwd() }) {
  const out = [];
  const rel = (f) => relative(dir, f) || f;
  const links = [];
  for (const sv of at(cfg, 'services') ?? []) if (typeof sv?.service === 'string' && typeof sv.binding === 'string') links.push({ kind: 'service', binding: sv.binding, target: sv.service, entrypoint: sv.entrypoint });
  for (const o of at(cfg, 'durable_objects.bindings') ?? []) if (typeof o?.script_name === 'string' && typeof o.name === 'string') links.push({ kind: 'object', binding: o.name, target: o.script_name, class: o.class_name });
  if (!links.length) return out;
  // The `roc build` command, with paths from the repo root (a platform path of an app can reach outside its directory).
  const buildHint = (wasm, src) => `: in ${rel(root)} run roc build --target=wasm32 --no-cache --output=${relative(root, wasm)} ${existsSync(src) ? relative(root, src) : '<its app.roc>'}`;
  const found = workers ?? findWorkers(root);
  const cache = new Map();
  for (const l of links) {
    const caller = m.bindings.find((b) => b.kind === l.kind && b.name === l.binding);
    const what = l.kind === 'service' ? `service ${l.binding} -> ${l.target}${l.entrypoint ? ` (entry point ${l.entrypoint})` : ''}` : `object ${l.binding} -> ${l.target} (class ${l.class})`;
    if (!caller) continue; // the config part that the app does not declare has its own note
    const note = (t) => out.push({ level: 'note', text: `${what}: ${t}` });
    const cands = found.filter((w) => w.name === l.target && resolve(w.file) !== resolve(cfgFile));
    if (!cands.length) {
      note(`no Wrangler config with name = "${l.target}" under ${rel(root)}: the link is not checked`);
      continue;
    }
    const wasms = [...new Set(cands.map(wasmOf))];
    if (cands.length > 1) note(`${cands.length} Wrangler configs have name = "${l.target}" (${cands.map((w) => rel(w.file)).join(', ')})${wasms.length > 1 ? ': they have different wasm files, so the link is not checked' : ''}`);
    if (wasms.length > 1) continue;
    const wasm = wasms[0];
    const tcfg = cands[0].file;
    if (!existsSync(wasm)) {
      const src = join(dirname(wasm), `${basename(wasm, '.wasm')}.roc`);
      note(`${rel(wasm)} (of ${rel(tcfg)}) is not there, so the link is not checked. Build it${buildHint(wasm, src)}`);
      continue;
    }
    const newer = sourcesOf(wasm).find((f) => statSync(f).mtimeMs > statSync(wasm).mtimeMs);
    if (newer) note(`${rel(wasm)} is older than ${rel(newer)}: build it again${buildHint(wasm, join(dirname(wasm), `${basename(wasm, '.wasm')}.roc`))}, or the check uses the old names`);
    let tm = cache.get(wasm);
    if (tm === undefined) {
      try {
        tm = manifestFor(wasm);
      } catch (e) {
        tm = { error: e.message };
      }
      cache.set(wasm, tm);
    }
    if (tm === null || tm?.error !== undefined || tm === undefined) {
      note(`${rel(wasm)}: no manifest to check (${tm?.error ?? 'the app has no Worker.new, or it is not stack-first'})`);
      continue;
    }
    let callee;
    let label;
    if (l.kind === 'service') {
      label = l.entrypoint ? `the entry point ${l.entrypoint}` : 'the default entry point';
      if (l.entrypoint && !Object.hasOwn(tm.entrypoints, l.entrypoint)) {
        out.push({ level: 'wrong', text: `${what}: ${rel(wasm)} has no entry point ${l.entrypoint} (it has ${Object.keys(tm.entrypoints).join(', ') || 'none'}). Check entrypoint in ${rel(cfgFile)}, or the entrypoints of Worker.new in the app of ${rel(tcfg)}` });
        continue;
      }
      callee = l.entrypoint ? tm.entrypoints[l.entrypoint].iface : tm.defaultIface;
    } else {
      label = `the class ${l.class}`;
      if (!Object.hasOwn(tm.objects, l.class)) {
        out.push({ level: 'wrong', text: `${what}: ${rel(wasm)} has no class ${l.class} (it has ${Object.keys(tm.objects).join(', ') || 'none'}). Check class_name in ${rel(cfgFile)}, or the objects of Worker.new in the app of ${rel(tcfg)}` });
        continue;
      }
      callee = tm.objects[l.class].iface;
    }
    // A side with no interface name (a class with no Rpc method, a Worker built before Rpc.iface) has nothing to compare.
    if (!caller.iface || !callee) out.push({ level: 'ok', text: `${what}: ${label} has ${callee ? 'an interface' : 'no Rpc method'}, so there is no interface to compare` });
    else if (caller.iface === callee) out.push({ level: 'ok', text: `${what}: interface ${JSON.stringify(callee)} (${rel(wasm)})` });
    else out.push({ level: 'wrong', text: `${what}: the interfaces differ. Caller: ${JSON.stringify(caller.iface)} in ${rel(cfgFile)} (${rel(wasmFile)}). Callee: ${JSON.stringify(callee)} in ${rel(tcfg)} (${rel(wasm)}). The Roc types cannot see across Workers: use the same Rpc.iface name on both sides, or fix the service or class in the Wrangler config` });
  }
  return out;
}

function sync(argv) {
  const a = parseArgs(argv, ['--check', '--force'], ['--wasm', '--entry', '--config', '--file']);
  if (a._.length) usage(`sync takes no argument ${a._[0]}`);
  const dir = process.cwd();
  const wasm = resolve(a.wasm ?? 'app.wasm');
  const entry = resolve(a.entry ?? 'worker.js');
  if (!existsSync(wasm)) usage(`${relative(dir, wasm)} is not there: build the app first (roc build --target=wasm32 --no-cache --output=app.wasm main.roc)`);
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
  // The options file of the entry file: the user's file, sync only imports it.
  const optionsFile = optionsFileOf(entry);
  const hasOptions = existsSync(optionsFile);
  const want = entryOf(m, wasmImport, shimImportOf(dirname(entry), here), hasOptions ? `./${basename(optionsFile)}` : null);
  const old = existsSync(entry) ? readFileSync(entry, 'utf8') : null;
  const name = relative(dir, entry);
  const counts = `${Object.keys(m.objects).length} object classes, ${Object.keys(m.entrypoints).length} entry points`;
  if (old === want) console.log(`${name}: up to date (${counts})`);
  else if (a.check) {
    console.log(`${name}: not the file that sync writes (${counts}). Run sync (node .roc-cfw/cli.mjs sync). The file:\n${want}`);
    fail = true;
  } else if (old !== null && !old.startsWith(MARK) && !a.force) {
    console.log(`${name}: not written: sync did not make it (no "${MARK}" line). Put these lines in it, or use --force:\n${want}`);
    fail = true;
  } else {
    writeFileSync(entry, want);
    console.log(`${name}: written (${counts})`);
  }
  if (hasOptions) {
    const optionsName = relative(dir, optionsFile);
    if (/\bexport\s+default\b|\bas\s+default\b/.test(readFileSync(optionsFile, 'utf8'))) console.log(`${optionsName}: the second argument of makeHandler`);
    else {
      console.log(`${optionsName}: has no default export. The entry file imports its default export: export default { ... }`);
      fail = true;
    }
  }

  // The handlers that the app defines and Worker.new does not list (a raw event! has no Worker.new to compare).
  const source = a.file ? resolve(a.file) : [join(dirname(wasm), `${basename(wasm, '.wasm')}.roc`), resolve('main.roc')].find((f) => existsSync(f));
  if (a.file && !existsSync(source)) usage(`${a.file} is not there`);
  if (source && got !== null) {
    for (const u of unlistedHandlers(m, readFileSync(source, 'utf8'))) {
      console.log(`sync: ${relative(dir, source)}:${u.line}: ${u.text}`);
      if (a.check) fail = true;
    }
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
  // The link to the other Workers of the repo: the interface names of the service bindings and of the namespaces.
  let links = [];
  try {
    const root = repoRoot(dirname(cfgFile));
    links = crossCheck(m, readConfig(cfgFile), {
      cfgFile,
      wasmFile: wasm,
      root,
      dir,
      manifestFor: (f) => {
        const got = manifestOf(new WebAssembly.Module(readFileSync(f)), manifestEvent());
        return got === undefined || got === null ? null : checkManifest(got);
      },
    });
  } catch (e) {
    console.error(`roc-cloudflare-workers: ${e.message}`);
    process.exit(2);
  }
  if (links.length) {
    console.log(`links to other Workers (${relative(dir, repoRoot(dirname(cfgFile))) || '.'}):`);
    for (const it of links) console.log(`  ${it.level.padEnd(7)} ${it.text}`);
  }
  // Two groups: the top-level keys (they go before the first table, and replace a key of the same name) and the
  // tables (at the end). A part of a note is a choice: it is shown as a comment.
  const adds = items.filter((it) => it.add && it.level !== 'ok');
  const show = (it) => (it.level === 'note' ? `# A choice (${it.text.split(':')[0]}):\n${it.add.replace(/^/gm, '# ')}` : it.add);
  const json = cfgFile.endsWith('.toml') ? '' : ' (as JSON)';
  const top = adds.filter((it) => !it.add.startsWith('['));
  const tables = adds.filter((it) => it.add.startsWith('['));
  if (top.length) console.log(`\nSet at the top of ${cfgName}${json}, before the first table (in place of a key of the same name):\n\n${top.map(show).join('\n')}`);
  if (tables.length) console.log(`\nAdd to the end of ${cfgName}${json}:\n\n${tables.map(show).join('\n\n')}`);
  if ([...items, ...links].some((it) => it.level === 'missing' || it.level === 'wrong')) fail = true;
  process.exit(fail ? 1 : 0);
}

// ---- main ----

// The command runs only when Node runs this file, not on an import of a test.
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
    else if (cmd === 'init') usage('init moved to the helper: roc-cfw init (research/talon-fit/TRANSITION.md)');
    else usage(cmd ? `unknown command ${cmd}` : undefined);
  } catch (e) {
    console.error(`roc-cloudflare-workers: ${e.message}`);
    process.exit(2);
  }
}
