// PLAN.md 11c: compares two result files of edge/run-edge.mjs (for example the edge runs of 0.0.9 and 0.0.10).
//   node edge/compare.mjs <a.txt> <b.txt> [label-a] [label-b] [conformance-dir-a] [conformance-dir-b]
// A name of a check can have ": " in it, so the names come from the check files of the two conformance directories
// (default: conformance/ of this checkout for both). Prints the counts of each file, then a Markdown table of each check
// whose outcome differs (PASS, FAIL, SKIP, or "-" when the check is not in that file), with the reason of the FAIL.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const [fa, fb, la = 'a', lb = 'b', ca = join(here, '../conformance'), cb = ca] = process.argv.slice(2);
const names = new Set();
for (const dir of new Set([resolve(ca), resolve(cb)])) {
  for (const f of readdirSync(join(dir, 'checks')).filter((x) => x.endsWith('.mjs'))) {
    for (const [name] of (await import(pathToFileURL(join(dir, 'checks', f)))).checks ?? []) names.add(name);
  }
}
const byLength = [...names].sort((x, y) => y.length - x.length);
const read = (f) => {
  const m = new Map();
  for (const line of readFileSync(f, 'utf8').split('\n')) {
    const x = /^(PASS|FAIL|SKIP) (.*)$/.exec(line);
    if (!x) continue;
    const name = byLength.find((n) => x[2] === n || x[2].startsWith(`${n}: `) || x[2].startsWith(`${n} (`));
    if (!name) throw new Error(`${f}: no check name for: ${line.slice(0, 120)}`);
    m.set(name, { st: x[1], why: x[2].slice(name.length).replace(/^: /, '') });
  }
  return m;
};
const a = read(fa), b = read(fb);
const count = (m, st) => [...m.values()].filter((v) => v.st === st).length;
console.log(`| Run | PASS | FAIL | SKIP | Checks |\n| --- | --- | --- | --- | --- |`);
for (const [l, m] of [[la, a], [lb, b]]) console.log(`| ${l} | ${count(m, 'PASS')} | ${count(m, 'FAIL')} | ${count(m, 'SKIP')} | ${m.size} |`);
const cell = (v) => (v ? v.st : '-');
const cut = (s) => s.replace(/\|/g, '\\|').slice(0, 160);
console.log(`\n| Check | ${la} | ${lb} | Reason of the FAIL |\n| --- | --- | --- | --- |`);
for (const name of [...new Set([...a.keys(), ...b.keys()])]) {
  const x = a.get(name), y = b.get(name);
  if (cell(x) === cell(y)) continue;
  const why = x?.st === 'FAIL' ? `${la}: ${x.why}` : y?.st === 'FAIL' ? `${lb}: ${y.why}` : '';
  console.log(`| ${cut(name)} | ${cell(x)} | ${cell(y)} | ${cut(why)} |`);
}
