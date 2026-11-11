// node bench/trap-reverts.mjs [name-filter]
// Revert checks of `on_trap` (design note research/design-notes/trap-response.md, plan S2 to S4): the tricky ones only.
// Each revert is a real edit of a JS file of the shim, a run of the tests that must catch it, and a restore of the file.
// The tests: bench/trap-test.mjs on bench/out (`node:<id>`), and the checks `trap:` of conformance/run.mjs in Miniflare
// (`conformance`). The Roc revert of S1 (the crash entry under the name default) is a `roc test` run: see PLAN.md.
// A change that finds no text to replace is an error (the code moved: update this list).
// Exit 1 when a revert is not caught by each check that it names, or the clean tree fails.
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const I = 'js/index.js', M = 'js/manifest.js';
const R = (name, checks, ...edits) => ({ name, checks, edits });
const reverts = [
  R('audit N13: the text names the manifest cause crash, not the Roc field crashed', ['node:1r', 'node:1r2'], [M, "on_trap.${field.replace(/^crash(?=\\.|\\[|$)/, 'crashed')}", 'on_trap.${field}']),
  R('S2: a body of 4,097 bytes passes (off by one)', ['node:1e'], [M, 'f.body.length > TRAP_LIMITS.bodyBytes', 'f.body.length > TRAP_LIMITS.bodyBytes + 1']),
  R('S3: the same body object for each response of a cause', ['node:4d', 'conformance'], [M, `  const f = traps[cause] ?? traps.default;
  const headers`, `  const f = traps[cause] ?? traps.default;
  if (f.made) return f.made;
  const headers`], [M, '  return new Response(f.body.slice(), { status: f.status, headers });', '  return (f.made = new Response(f.body.slice(), { status: f.status, headers }));']),
  R('S3: fetchLike skips the table', ['node:4h', 'node:4i', 'node:4j', 'conformance'], [I, '    if (r.trap) return trapResponse(manifest.traps, r, retryAfter);', '    if (r.trap) return trapResponse(null, r, retryAfter);'], [I, '    log(`${tag}: ${reason(r.outcome)}`);\n    return trapResponse(manifest.traps, r, retryAfter);', '    log(`${tag}: ${reason(r.outcome)}`);\n    return trapResponse(null, r, retryAfter);']),
  R('S3: oom is mapped to crash', ['node:2a', 'node:4o'], [M, "if (r.cause === 'oom' || r.cause === 'cpu'", "if (r.cause === 'cpu'"]),
  R('S3: no retry-after when the entry has headers', ['node:4p'], [M, "if (retry && !headers.has('retry-after'))", "if (retry && !f.headers.length && !headers.has('retry-after'))"]),
  R('S4: a host export (log_len, as drain) is called to make the response', ['node:5'], [I, `      if (r.trap) {
        if (hooks.passThrough`, `      if (r.trap) {
        r.x?.log_len?.();
        if (hooks.passThrough`], [I, `    if (r.trap) return trapResponse(manifest.traps, r, retryAfter);`, `    if (r.trap) return (r.x?.log_len?.(), trapResponse(manifest.traps, r, retryAfter));`]),
];

const filter = process.argv[2];
const sh = (args) => spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8', timeout: 600000 });
const ids = (text) => [...text.matchAll(/^FAIL (\w+)[: ]/gm)].map((m) => m[1]);
const node = () => {
  const r = sh(['bench/trap-test.mjs', 'bench/out']);
  return { pass: r.status === 0, failed: ids(r.stdout + r.stderr).map((x) => `node:${x}`), text: r.stdout + r.stderr };
};
const conformance = () => {
  const r = sh(['conformance/run.mjs', 'bench/out/conformance.wasm', 'trap:']);
  return { pass: r.status === 0, failed: r.status === 0 ? [] : ['conformance'], text: r.stdout + r.stderr };
};
const caughtBy = (check, failed) => failed.some((f) => f === check || (f.startsWith(check) && /^[a-z]$/.test(f.slice(check.length))));

const chosen = reverts.filter((rv) => !filter || rv.name.includes(filter));
const needsConf = chosen.some((rv) => rv.checks.includes('conformance'));
const clean = [node(), ...(needsConf ? [conformance()] : [])];
if (!clean.every((t) => t.pass)) {
  console.log('the clean tree fails:', clean.map((t) => t.text.slice(-800)).join('\n'));
  process.exit(1);
}
console.log('clean tree: PASS');
let bad = false;
for (const rv of chosen) {
  const saved = new Map();
  try {
    for (const [file, from, to] of rv.edits) {
      const path = root + file;
      if (!saved.has(file)) saved.set(file, readFileSync(path, 'utf8'));
      const s = readFileSync(path, 'utf8');
      if (!s.includes(from)) throw new Error(`no text to replace in ${file}: ${from.slice(0, 60)}`);
      writeFileSync(path, s.replace(from, to));
    }
    const runs = [node(), ...(rv.checks.includes('conformance') ? [conformance()] : [])];
    const failed = runs.flatMap((t) => t.failed);
    const missed = rv.checks.filter((c) => !caughtBy(c, failed));
    if (missed.length) {
      bad = true;
      console.log(`NOT CAUGHT ${rv.name}: ${missed.join(', ')} (failed: ${failed.join(', ') || 'none'})`);
    } else console.log(`caught ${rv.name}: ${failed.join(', ')}`);
  } catch (e) {
    bad = true;
    console.log(`ERROR ${rv.name}: ${e.message}`);
  } finally {
    for (const [file, s] of saved) writeFileSync(root + file, s);
  }
}
process.exit(bad ? 1 : 0);
