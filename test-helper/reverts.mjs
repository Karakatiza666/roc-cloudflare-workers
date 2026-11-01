// Revert checks of the test helper (research/design-notes/test-helper.md 7 and 10): each entry breaks one tricky behavior
// in the source, runs the test that must see it, and puts the source back. The entry passes when the test fails with the
// expected line. Run only the entries that a change touches (a filter is required, no full sweep).
//   node test-helper/reverts.mjs <name-filter ...>       node test-helper/reverts.mjs --list
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const helper = (filter) => ['node', ['test-helper/helper-test.mjs', '', '', filter]];

const REVERTS = [
  {
    name: 'S2 wrapEnv in Handler.fetch only, not in run',
    edits: [
      ['js/index.js', '    if (wrapEnv) ro.env = wrapEnv(ro.env, { kind: ro.kind, name, event: ro.event });\n', ''],
      ['js/index.js', "{ kind: 'Fetch', signal: request.signal, env: this.env, ctx: this.ctx, event: request, hooks });", "{ kind: 'Fetch', signal: request.signal, env: wrapEnv ? wrapEnv(this.env, { kind: 'Fetch', name: 'fetch', event: request }) : this.env, ctx: this.ctx, event: request, hooks });"],
    ],
    run: ['node', ['test-helper/wrapenv-test.mjs']],
    want: /FAIL Init: one call/,
  },
  {
    name: 'S3 count prepare as a call',
    edits: [['js/test-entry.js', "        if (k === 'prepare') return (...a) => stmt(f(...a), session);", "        if (k === 'prepare') return (...a) => (rec(k, session), stmt(f(...a), session));"]],
    run: ['node', ['test-helper/count-test.mjs']],
    want: /FAIL D1: prepare and bind are not calls/,
  },
  {
    name: 'S4 drop the text-to-bytes conversion of the body',
    edits: [['js/test.mjs', "const body = typeof rest.body === 'string' ? Buffer.from(rest.body) : rest.body;", 'const body = rest.body;']],
    run: helper('H3 T1'),
    want: /FAIL H3 T1/,
  },
  {
    name: 'S4 drop the force-cache default',
    edits: [['js/test.mjs', "cache: rest.cache ?? 'force-cache',", 'cache: rest.cache,']],
    run: helper('H3 T2'),
    want: /FAIL H3 T2/,
  },
  {
    name: 'S4 key the run dir by pid only',
    edits: [['js/test.mjs', 'const runDir = join(baseTmp, `cfw-test-${process.pid}-${n}`);', 'const runDir = join(baseTmp, `cfw-test-${process.pid}-0`);']],
    run: helper('TH9: two apps'),
    want: /FAIL TH9: two apps/,
  },
  {
    name: 'S4 key the counts globally, not by request',
    edits: [
      ['js/test-entry.js', '        const rec = { calls: [], sessions: {} };\n', '        const rec = { calls: [], sessions: {} };\n        const start0 = calls.length;\n'],
      ['js/test-entry.js', 'encodeURIComponent(JSON.stringify(rec))', 'encodeURIComponent(JSON.stringify({ ...rec, calls: calls.slice(start0) }))'],
    ],
    run: helper('two requests at the same time'),
    want: /FAIL H5 TH4: two requests/,
  },
  {
    name: 'S5 record only the keys of caches.default, not of caches.open names',
    edits: [['js/test-entry.js', '        if (!named.has(name)) named.set(name, wrapCache(c, name));\n        return named.get(name);', '        return c;']],
    run: helper('H9'),
    want: /FAIL H9: .*cache named/,
  },
  {
    name: 'TH18 no default Content-Length of an answer',
    edits: [['js/test.mjs', "  if (!headers.has('content-length')) headers.set('content-length', String(b.length));\n", '']],
    run: helper('TH18: an answer'),
    want: /FAIL TH18: an answer/,
  },
];

const args = process.argv.slice(2);
if (!args.length || args[0] === '--list') {
  for (const r of REVERTS) console.log(r.name);
  if (!args.length) console.log('give one or more name filters (no full sweep)');
  process.exit(args.length ? 0 : 2);
}
let bad = 0;
for (const r of REVERTS.filter((x) => args.some((a) => x.name.includes(a)))) {
  const saved = new Map();
  try {
    for (const [file, from, to] of r.edits) {
      const p = join(root, file);
      if (!saved.has(p)) saved.set(p, readFileSync(p, 'utf8'));
      const text = readFileSync(p, 'utf8');
      if (text.split(from).length !== 2) throw new Error(`${file}: the text to revert is not there once: ${from.slice(0, 60)}`);
      writeFileSync(p, text.replace(from, to));
    }
    let out = '';
    try {
      out = execFileSync(r.run[0], r.run[1], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 300_000 });
    } catch (e) {
      out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
    }
    const hit = r.want.test(out);
    if (!hit) bad++;
    console.log(`${hit ? 'PASS' : 'FAIL'} revert "${r.name}": ${hit ? 'the test sees it' : `the test does not see it:\n${out.split('\n').slice(-8).join('\n')}`}`);
  } catch (e) {
    bad++;
    console.log(`FAIL revert "${r.name}": ${e.message}`);
  } finally {
    for (const [p, text] of saved) writeFileSync(p, text);
  }
}
process.exit(bad ? 1 : 0);
