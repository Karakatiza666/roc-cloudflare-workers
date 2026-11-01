// node bench/cli-reverts.mjs [name-filter]   (needs bench/out/app_b3.wasm: bench/build.sh)
// Revert checks for bench/cli-test.mjs: it copies js/ and the test to .cache/cli-reverts/, breaks one rule of js/cli.mjs
// in the copy, runs the test, and checks that a test that must catch it fails. The files in js/ are not changed.
// A change that finds no text to replace is an error (the code moved: update this list).
// Exit 1 when the clean copy fails, a revert is not caught, or a revert breaks the test run.
import { cpSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const work = `${root}.cache/cli-reverts`;

// name, the test names that must fail (a regex on the text after FAIL), edits: [from, to].
const R = (name, expect, ...edits) => ({ file: 'js/cli.mjs', name, expect, edits });
const mutations = [
  // E4, the Roc nightly (README "Supported nightlies"). Names start with "nightly" (`node bench/cli-reverts.mjs nightly`).
  R('nightly: a wasm with no stack exports is not a proof (falls to the pin)', /^8h |^8n /, ["if (!stackExports && minDate >= STACK_EXPORTS_FROM) return [{ level: 'wrong'", "if (false) return [{ level: 'wrong'"]),
  R('nightly: the pin is compared the wrong way', /^8i |^8q /, ['if (pinDate < minDate) return', 'if (pinDate > minDate) return']),
  R('nightly: a warn does not fail --check', /^8r /, ["if (it.level === 'wrong' || (it.level === 'warn' && a.check)) fail = true;", "if (it.level === 'wrong') fail = true;"]),
  R('nightly: sync reads another key of cfw.json', /^8m |^8n /, ["'utf8')).min_nightly ?? null;", "'utf8')).minNightly ?? null;"]),
];

const filter = process.argv[2];
const run = () => {
  const r = spawnSync(process.execPath, ['bench/cli-test.mjs', `${root}bench/out`], { cwd: work, encoding: 'utf8', timeout: 300000 });
  const out = (r.stdout || '') + (r.stderr || '');
  const failed = out.split('\n').filter((l) => l.startsWith('FAIL ')).map((l) => l.slice(5).trim());
  return { failed, finished: /^(all passed|FAILED)$/m.test(out), out };
};
// The test reads js/, bench/cf-node.mjs and the app sources of section 6 (conformance/, bench/*.roc) from its root.
const fresh = () => {
  rmSync(work, { recursive: true, force: true });
  mkdirSync(`${work}/bench`, { recursive: true });
  cpSync(`${root}js`, `${work}/js`, { recursive: true });
  for (const f of ['cli-test.mjs', 'cf-node.mjs', 'cf-workers-stub.mjs', 'app_events.roc', 'app_b3.roc', 'app_link_callee.roc']) cpSync(`${root}bench/${f}`, `${work}/bench/${f}`);
  symlinkSync(`${root}conformance`, `${work}/conformance`);
};

let bad = 0;
fresh();
const base = run();
console.log(`clean copy: ${base.finished && base.failed.length === 0 ? 'all tests pass' : 'FAILS'}`);
if (!base.finished || base.failed.length) { console.log(base.out.slice(-1500)); process.exit(1); }

const rows = [];
for (const m of mutations) {
  if (filter && !m.name.includes(filter)) continue;
  fresh();
  let text = readFileSync(`${work}/${m.file}`, 'utf8');
  for (const [from, to] of m.edits) {
    if (!text.includes(from)) { console.log(`ERROR  ${m.name}: text not found in ${m.file}: ${from.slice(0, 60)}`); bad++; text = null; break; }
    text = text.replace(from, () => to);
  }
  if (text === null) continue;
  writeFileSync(`${work}/${m.file}`, text);
  const r = run();
  const caught = r.finished && r.failed.some((n) => m.expect.test(n));
  if (!caught) bad++;
  rows.push({ revert: m.name, result: !r.finished ? 'CRASH' : caught ? 'caught' : 'NOT CAUGHT', 'failed tests': r.failed.length, 'first failed': (r.failed[0] || '').slice(0, 70) });
}
console.table(rows);
console.log(`${rows.length - bad} of ${rows.length} reverts caught${bad ? `, ${bad} not` : ''}`);
rmSync(work, { recursive: true, force: true });
process.exit(bad ? 1 : 0);
