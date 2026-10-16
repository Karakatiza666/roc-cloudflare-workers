// node bench/native-reverts.mjs [name-filter]   (env: ZIG, ROC)
// Revert checks for bench/native-test.mjs (PLAN.md 8e). Each revert is a real edit of a source file, a build of the
// bench host and of bench/app_native.roc into .cache/native-reverts/, a run of the test, and a restore of the file.
// A change that finds no text to replace is an error (the code moved: update this list).
// At the end it builds the clean tree again (bench/build.sh), because `zig build` writes the host object in place.
// Exit 1 when a revert is not caught by the test that it names, or the clean tree fails.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ZIG = process.env.ZIG, ROC = process.env.ROC;
if (!ZIG || !ROC) throw new Error('set ZIG and ROC');
const out = `${root}.cache/native-reverts`;
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache`, ZIG_GLOBAL_CACHE_DIR: `${root}.cache/zig` };
const N = 'hostlib/native/native.zig', Z = 'hostlib/native/zstd.zig', A = 'hostlib/alloc.zig', H = 'host/host.zig';
// name, the checks of native-test.mjs that must fail (the name after FAIL: a test, or a check in the test `handles`), edits: [file, from, to].
const R = (name, tests, ...edits) => ({ name, tests, edits });
const reverts = [
  R('no output limit in zstd_decode (limit 1 GB)', ['limit'], [N, 'return bytes(try zstd.decode(a, in[4..], max_out));', 'return bytes(try zstd.decode(a, in[4..], @max(max_out, 1 << 30)));']),
  R('BLAKE3 state is reset at each update', ['hash'], [N, '@as(*T, @ptrFromInt(s.ptr)).update(in[4..]);', '@as(*T, @ptrFromInt(s.ptr)).* = if (T == Blake3) Blake3.init(.{}) else Sha256.init(.{});\n    @as(*T, @ptrFromInt(s.ptr)).update(in[4..]);']),
  R('no owner check in lookup (another task)', ['wrongtask'], [N, 'if (s.owner != owner) return error.WrongTask;', 'if (s.owner != owner and false) return error.WrongTask;']),
  R('no endTask hook in taskEnd (the slots stay)', ['endtask'], [A, '@import("native/native.zig").endTask(allocator, owner, .forget);', '']),
  R('no push_limit check in the stream', ['stream'], [Z, 'if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);', '']),
  R('a handle that was closed is still a handle (no check of used and gen)', ['twice'], [N, 'if (!s.used or s.gen != handle >> 8) return error.BadHandle;', 'if (false) return error.BadHandle;']),
  R('no cap of handles for a task', ['many'], [N, 'if (mine >= MAX_PER_TASK or free == null) return error.TooManyHandles;', 'if (free == null) return error.TooManyHandles;']),
  R('no window limit check in open', ['limits'], [N, 'if (w > zstd.WINDOW_MAX) return error.BadArgument;', '']),
  R('the result copy drops its last byte', ['decode', 'hash'], [H, 'return .{ .bytes = Bytes.fromSlice(r.bytes, ROC_HOST), .status = r.status };', 'return .{ .bytes = Bytes.fromSlice(r.bytes[0 .. r.bytes.len -| 1], ROC_HOST), .status = r.status };']),
  R('no stack reserve before the op (the 274 KB frame can reach the canary)', ['deep'], [H, 'lib.canary.reserve(lib.native.stackNeed(op));', '']),
  R('status 4 is not a trap (an out of memory gives an empty result)', ['oom'], [H, 'if (r.status == 4) lib.cpu.oom();', '']),
];

const filter = process.argv[2];
const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: root, env, encoding: 'utf8', timeout: 600000, ...opts });
const build = () => {
  const z = sh(ZIG, ['build', '-Dbench=true']);
  if (z.status !== 0) return `zig build failed: ${z.stderr.slice(-300)}`;
  mkdirSync(out, { recursive: true });
  const r = sh(ROC, ['build', '--opt=speed', '--target=wasm32', '--no-cache', `--output=${out}/app_native.wasm`, 'bench/app_native.roc']);
  if (r.status !== 0 && r.status !== 2) return `roc build failed: ${r.stdout.slice(-300)}`;
  return null;
};
const test = (only) => {
  const r = sh(process.execPath, ['bench/native-test.mjs', `${out}/app_native.wasm`, ...(only ? [only] : [])]);
  const text = r.stdout + r.stderr;
  return { pass: r.status === 0, failed: [...text.matchAll(/^FAIL (\w+)/gm)].map((m) => m[1]), text };
};

let bad = false;
const clean = build() ?? test();
if (clean.pass !== true && clean.pass !== undefined) {
  console.log('the clean tree fails:', clean);
  process.exit(1);
}
console.log('clean tree: PASS');
for (const rv of reverts) {
  if (filter && !rv.name.includes(filter)) continue;
  const saved = new Map();
  try {
    for (const [f, from, to] of rv.edits) {
      const path = root + f;
      if (!saved.has(f)) saved.set(f, readFileSync(path, 'utf8'));
      const s = readFileSync(path, 'utf8');
      if (!s.includes(from)) throw new Error(`no text to replace in ${f}: ${from.slice(0, 60)}`);
      writeFileSync(path, s.replace(from, to));
    }
    const err = build();
    if (err) {
      console.log(`${rv.name}: ${err}`);
      bad = true;
      continue;
    }
    const t = test();
    const caught = !t.pass && rv.tests.every((name) => t.failed.includes(name));
    console.log(`${rv.name}: ${t.pass ? 'NOT CAUGHT (the test passed)' : `FAIL in [${[...new Set(t.failed)]}]`}${caught ? '' : `, but the test did not fail in all of [${rv.tests}]`}`);
    const line = t.text.split('\n').find((l) => l.startsWith('FAIL'));
    if (line) console.log(`  first: ${line.slice(0, 220)}`);
    if (!caught) bad = true;
  } finally {
    for (const [f, text] of saved) writeFileSync(root + f, text);
  }
}
const final = sh('bash', ['bench/build.sh']);
console.log(`clean build again: ${final.status === 0 ? 'ok' : 'FAILED'}`);
if (final.status !== 0) bad = true;
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
