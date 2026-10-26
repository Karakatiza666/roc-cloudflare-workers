// node bench/stream-reverts.mjs [name-filter]   (env: ROC, WORKERD)
// Revert checks for bench/stream-test.mjs (Node) and bench/stream-workerd.mjs (workerd): PLAN.md 8b (second half), 9c,
// 10a, 10b. Each revert is a real edit of a source file, a run of the tests that must catch it, and a restore of the
// file. A JS revert runs the tests on bench/out/app_stream.wasm. A Roc revert builds bench/app_stream.roc into
// bench/out/app_stream.wasm (the workerd config embeds that file), runs the tests, and puts the old wasm back. A change
// that finds no text to replace is an error (the code moved: update this list). A test that hangs is stopped after 90 s:
// its FAIL lines up to then count (a revert can make a stream wait forever).
// Exit 1 when a revert is not caught by each check that it names, or the clean tree fails.
import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const { ROC, WORKERD } = process.env;
if (!ROC || !WORKERD) throw new Error('set ROC and WORKERD');
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache` };
const I = 'js/index.js', E = 'js/events.js', HP = 'js/helpers.js', T = 'js/tasks.js', B = 'platform/Body.roc', C = 'platform/Ctx.roc';
// name, kind ('js' or 'build'), the checks that must fail: `node:<id>` (the FAIL lines of stream-test.mjs) and
// `workerd:<id>` (of stream-workerd.mjs), edits: [file, from, to]. A Roc file of platform/ is edited in both copies.
const R = (name, kind, checks, ...edits) => ({ name, kind, checks, edits });
const reverts = [
  R('10a: the request body is copied into wasm (bytes, not a stream)', 'js', ['node:10a', 'workerd:10a'],
    [E, 'body: bodyIn(request)', 'body: request.body === null ? undefined : new Uint8Array(await request.arrayBuffer())']),
  R('10b: chunk gives the whole rest of the stream (copy all)', 'js', ['node:10b', 'workerd:10b'],
    [HP, '      if (!value) return undefined;\n', '      if (!value) return undefined;\n      for (const all = [value]; ; ) {\n        const g = await r.reader.read();\n        if (g.done) {\n          r.done = true;\n          value = concat(all, all.reduce((n, c) => n + c.byteLength, 0));\n          max = Infinity;\n          break;\n        }\n        all.push(bytesOf(g.value));\n      }\n']),
  R('10b: bytes_with! of a stream reads it all into wasm, Roc checks the length', 'build', ['node:10b'],
    [B, '[Lit(Ref(r)), Lit(Int(limit(max_bytes)))]', '[Lit(Ref(r)), Lit(Int(I64.highest))]']),
  R('decompress! with the wrong format name', 'js', ['node:compress', 'workerd:compress'],
    [HP, '      const t = new T(format);', "      const t = new T(kind === 'decompress' ? (format === 'gzip' ? 'deflate' : 'gzip') : format);"]),
  R('Response.after gives no response at once (the shim responds at the task end)', 'js', ['node:after', 'workerd:after', 'workerd:late'],
    [HP, '      h.respond(res);\n', '']),
  R('a second Response.after replaces the first', 'build', ['node:twice'],
    ['platform/Response.roc', '\t\t\t\t\tfirst!({})?\n', '']),
  R('pass_through! in any event (no check of the kind)', 'js', ['node:scheduled'],
    [HP, "if (h?.kind !== 'Fetch' || typeof h.ctx?.passThroughOnException", "if (typeof h?.ctx?.passThroughOnException"]),
  R('pass_through!: an Err always gives a 500', 'js', ['node:pass'],
    [I, "      if (hooks.passThrough && r.outcome.outcome === 'failed') throw new Error(`fetch: ${reason(r.outcome)}`);\n", '']),
  R('respond! does not tell the task table (no 30 s limit after it)', 'js', ['node:deadline'],
    [HP, '      tasks.respond(t, Boolean(s && !s.closed));\n', '']),
  R('the shim reads the stream to its end before it responds', 'js', ['node:writer', 'workerd:writer'],
    [I, '        return hooks.response;', '        const all = await hooks.response.arrayBuffer();\n        return new Response(all, { status: hooks.response.status, headers: hooks.response.headers });']),
  R('the limit starts at respond! (also for an open writer stream)', 'js', ['node:writer'],
    [HP, '      tasks.respond(t, Boolean(s && !s.closed));', '      tasks.respond(t, false);']),
  R('no cancel when the reader cancels the stream', 'js', ['node:cancel'],
    [HP, "        if (!s.closed && t && !t.ended) tasks.cancel(t, 'stream');\n", '']),
  // workerd 2026-10-23 cancels the response stream too (E11), so `away` fails only when both cancels are gone. A revert of
  // request.signal alone: bench/signal-workerd.mjs fails (a waiting task with no stream).
  R('no request.signal and no stream cancel for the task (the client that goes away)', 'js', ['workerd:away'],
    [I, "{ kind: 'Fetch', signal: request.signal, env: this.env", "{ kind: 'Fetch', signal: undefined, env: this.env"],
    [HP, "        if (!s.closed && t && !t.ended) tasks.cancel(t, 'stream');\n", '']),
  R('9c: wait_until! does not call ctx.waitUntil', 'build', ['node:waituntil', 'workerd:waituntil'],
    [C, ', Call(Root("ctx"), "waitUntil", [Slot(0)])]', ']']),
  R('9c: the context of a task is freed at its end (no wait for its started programs)', 'js', ['node:started'],
    [T, '      if (t.spawns === 0) freeContext(t);\n      else lingering.add(t);', '      freeContext(t);']),
  R('9c: no waitUntil limit for the context of a started program', 'js', ['node:linger'],
    [T, '        if (at < lingerUntil(t, d)) continue;', '        continue;']),
  R('9c: a started program that throws gives no log line', 'js', ['node:startlog'],
    [HP, "          shim.log?.(`started program failed:", "          void (`started program failed:"]),
];

const filter = process.argv[2];
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: root, env, encoding: 'utf8', timeout: 600000, ...opts });
const wasm = `${root}bench/out/app_stream.wasm`;
const saved = `${root}.cache/app_stream.clean.wasm`;
const build = () => {
  const r = sh(ROC, ['build', '--opt=speed', '--target=wasm32', '--no-cache', `--output=${wasm}`, 'bench/app_stream.roc']);
  return r.status !== 0 && r.status !== 2 ? `roc build failed: ${(r.stdout + r.stderr).slice(-300)}` : null;
};
// The ids of the FAIL lines: `FAIL 10a: ...` gives 10a.
const ids = (text) => [...text.matchAll(/^FAIL (\w+):/gm)].map((m) => m[1]);
const run = (test, prefix) => {
  const r = sh(process.execPath, [test, ...(prefix === 'node' ? [wasm] : [])], { timeout: 90000 });
  // A test stopped at the timeout leaves its workerd: the next run would find the port in use.
  if (prefix === 'workerd') sh('pkill', ['-KILL', '-f', 'bench/config-stream.capnp']);
  const text = (r.stdout ?? '') + (r.stderr ?? '');
  return { pass: r.status === 0, hung: r.status === null, failed: ids(text).map((x) => `${prefix}:${x}`), text };
};
const both = () => [run('bench/stream-test.mjs', 'node'), run('bench/stream-workerd.mjs', 'workerd')];

let bad = false;
const clean = both();
if (!clean.every((t) => t.pass)) {
  console.log('the clean tree fails:', clean.map((t) => t.text.slice(-800)).join('\n'));
  process.exit(1);
}
console.log('clean tree: PASS (Node and workerd)');
copyFileSync(wasm, saved);
for (const rv of reverts) {
  if (filter && !rv.name.includes(filter)) continue;
  const files = new Map();
  try {
    for (const [f, from, to] of rv.edits) {
      for (const file of f.startsWith('platform/') ? [f, `bench/${f}`] : [f]) {
        const path = root + file;
        if (!files.has(file)) files.set(file, readFileSync(path, 'utf8'));
        const s = readFileSync(path, 'utf8');
        if (!s.includes(from)) throw new Error(`no text to replace in ${file}: ${from.slice(0, 60)}`);
        writeFileSync(path, s.replace(from, to));
      }
    }
    if (rv.kind === 'build') {
      const err = build();
      if (err) {
        console.log(`${rv.name}: ${err}`);
        bad = true;
        continue;
      }
    }
    const runs = both();
    const failed = runs.flatMap((t) => t.failed);
    const caught = rv.checks.every((c) => failed.includes(c));
    const passed = runs.every((t) => t.pass);
    const hung = runs.filter((t) => t.hung).map((t) => t.failed[0]?.split(':')[0] ?? 'a test');
    console.log(`${rv.name}: ${passed ? 'NOT CAUGHT (the tests passed)' : `FAIL in [${failed}]`}${hung.length ? ` (stopped after 90 s: ${hung})` : ''}${caught ? '' : `, but not in each of [${rv.checks}]`}`);
    for (const t of runs) {
      const line = t.text.split('\n').find((l) => l.startsWith('FAIL '));
      if (line) console.log(`  first: ${line.slice(0, 220)}`);
    }
    if (!caught) bad = true;
  } finally {
    for (const [f, text] of files) writeFileSync(root + f, text);
    if (rv.kind === 'build') copyFileSync(saved, wasm);
  }
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
