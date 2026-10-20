// node research/revert-static-check/check.mjs
// A static check of the revert lists, with no build: for each entry, each search text must be in its file (the edits of
// an entry apply in order, as the runners do). For `conformance/reverts.mjs`, each name in `checks` must also be in a
// file of conformance/checks/ (a name made by a template matches as a pattern). Exit 1 when one entry is stale.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../..', import.meta.url));
const read = (f) => readFileSync(root + f, 'utf8');
// The array of entries: the source from `const R =` to the first line `];`, run with the constants of its file.
const entries = (file, consts) => {
  const src = read(file);
  const a = src.indexOf('const R = ');
  const b = src.indexOf('\n];', a) + 3;
  const code = `${consts}\n${src.slice(a, b)}\nreturn ${/const (mutations|reverts) = \[/.exec(src)[1]};`;
  return new Function(code)();
};

const stale = [];
let n = 0;
const checkEdits = (list, label, edits, shape) => {
  const texts = new Map();
  for (const e of edits) {
    const [f, from] = shape(e);
    if (!texts.has(f)) {
      if (!existsSync(root + f)) { console.log(`skipped (no file ${f}): ${label}`); break; }
      texts.set(f, read(f));
    }
    if (!texts.get(f).includes(from)) stale.push(`${label}: no text in ${f}: ${JSON.stringify(from.slice(0, 70))}`);
    else texts.set(f, texts.get(f).replace(from, () => e[2] ?? ''));
  }
};

const checkSrc = readdirSync(`${root}conformance/checks`).map((f) => read(`conformance/checks/${f}`)).join('\n');
// A check name made by a template (`dec encode: ... "${name}" ...`) matches as a pattern.
const templates = [...checkSrc.matchAll(/`([^`\n]*\$\{[^`\n]*)`/g)].map((m) => new RegExp(`^${m[1].split(/\$\{[^}]*\}/).map((x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.+')}`));
const consts = "const BP = 'bench/platform/', IX = 'js/index.js', CBOR = '.cache/roc/packages/GTUNBR1419Xvgw1eightgb14scrrWkoiTVkBPJ94yHMA/Cbor.roc';\nconst P = CBOR;";
for (const r of entries('conformance/reverts.mjs', consts)) {
  n++;
  checkEdits(n, `conformance/reverts.mjs: ${r.name}`, r.edits, (e) => [e[0], e[1]]);
  for (const c of r.test === 'conformance' ? r.checks ?? [] : []) {
    const esc = (q) => c.replaceAll('\\', '\\\\').replaceAll(q, `\\${q}`);
    if (![c, esc("'"), esc('"'), esc('`')].some((v) => checkSrc.includes(v)) && !templates.some((t) => t.test(c))) stale.push(`conformance/reverts.mjs: ${r.name}: no check named ${JSON.stringify(c.slice(0, 70))}`);
  }
}
for (const m of entries('bench/cbor-js-reverts.mjs', "const root = '';")) {
  n++;
  const texts = new Map();
  checkEdits(n, `bench/cbor-js-reverts.mjs: ${m.name}`, m.edits.map((e) => [m.file, e[0], e[1]]), (e) => [e[0], e[1]]);
}
console.log(`${n} entries checked, ${stale.length} stale`);
for (const s of stale) console.log(`STALE ${s}`);
process.exit(stale.length ? 1 : 0);
