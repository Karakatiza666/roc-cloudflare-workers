// The link across Workers that `roc-cloudflare-workers sync` checks (MODULES.md 3, js/cli.mjs `crossCheck`). Node only.
// node bench/sync-cross-test.mjs [dir with the wasm files]    (default: bench/out)
//   app_link_caller.wasm    service LEDGER (Ledger), service ADMIN (AdminApi), namespace ROOMS (class Room, RoomApi, script callee)
//   app_link_callee.wasm    default Ledger, entry point Admin (AdminApi), class Room (RoomApi), class Plain (no Rpc method)
//   app_link_callee_b.wasm  the same app with the interface names LedgerB, AdminApiB, RoomApiB
//   app_b3.wasm             a callee with no Rpc method at all
// Each case is a repo dir (a `.git` dir) with the Worker `caller` and the Worker `callee`, each with a Wrangler config and an app.wasm.
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const wasmDir = resolve(process.argv[2] ?? join(root, 'bench/out'));
const W = (f) => join(wasmDir, `${f}.wasm`);
const cli = join(root, 'js/cli.mjs');
const tmp = mkdtempSync(join(tmpdir(), 'sync-cross-'));
process.on('exit', () => rmSync(tmp, { recursive: true, force: true }));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const check = (name, cond, why) => (cond ? pass(name) : fail(`${name}: ${why}`));

// The config of the caller that the app declares in full: sync gives exit 0 when the links are good.
const callerConfig = (edit = (c) => c) =>
  edit({
    name: 'caller',
    main: 'worker.js',
    compatibility_date: '2026-10-01',
    compatibility_flags: ['enable_request_signal', 'global_fetch_strictly_public'],
    services: [
      { binding: 'LEDGER', service: 'callee' },
      { binding: 'ADMIN', service: 'callee', entrypoint: 'Admin' },
    ],
    durable_objects: { bindings: [{ name: 'ROOMS', class_name: 'Room', script_name: 'callee' }] },
  });

let k = 0;
// A repo: `.git`, the Worker `caller` and the Worker `callee` (the wasm of each). Returns the dirs.
function repo({ callee = 'app_link_callee', config = callerConfig(), git = true, calleeName = 'callee' } = {}) {
  const r = join(tmp, `r${k++}`);
  mkdirSync(join(r, 'caller'), { recursive: true });
  mkdirSync(join(r, 'callee'), { recursive: true });
  if (git) mkdirSync(join(r, '.git'));
  copyFileSync(W('app_link_caller'), join(r, 'caller/app.wasm'));
  writeFileSync(join(r, 'caller/wrangler.json'), JSON.stringify(config));
  copyFileSync(W(callee), join(r, 'callee/app.wasm'));
  writeFileSync(join(r, 'callee/wrangler.json'), JSON.stringify({ name: calleeName, compatibility_date: '2026-10-01' }));
  return { r, caller: join(r, 'caller'), callee: join(r, 'callee') };
}
const run = (dir, ...args) => {
  const p = spawnSync(process.execPath, [cli, ...args], { cwd: dir, encoding: 'utf8' });
  return { code: p.status, out: p.stdout, err: p.stderr, all: p.stdout + p.stderr };
};
// The lines of the section "links to other Workers" of the output.
const links = (out) => {
  const i = out.indexOf('links to other Workers');
  return i < 0 ? '' : out.slice(i).split('\n\n')[0];
};
const has = (out, ...res) => res.filter((re) => !re.test(links(out)));
// A line of the section: the level, the link (`service LEDGER`, `object ROOMS`), the rest of the line (a regex).
const link = (lvl, what, rest) => new RegExp(`^ {2}${lvl} +${what} -> \\w+(?: \\(.*?\\))?: ${rest}`, 'm');
const LEDGER = (lvl, rest) => link(lvl, 'service LEDGER', rest);
const ADMIN = (lvl, rest) => link(lvl, 'service ADMIN', rest);
const ROOMS = (lvl, rest) => link(lvl, 'object ROOMS', rest);
const expectLinks = (name, r, code, ...res) => {
  const miss = has(r.out, ...res);
  check(name, r.code === code && miss.length === 0, `exit ${r.code} (want ${code}), not in the links section: ${miss.join(' ')}\n${r.all}`);
};

// ---- 1. The same interface names on both sides: ok, exit 0, --check too ----
{
  const d = repo();
  const r = run(d.caller, 'sync');
  expectLinks('1a match: the three links are ok with the interface name, exit 0', r, 0, LEDGER('ok', 'interface "Ledger"'), ADMIN('ok', 'interface "AdminApi"'), ROOMS('ok', 'interface "RoomApi"'));
  check('1b match: no wrong and no missing line anywhere', !/^ {2}(wrong|missing)/m.test(r.out), r.out);
  const c = run(d.caller, 'sync', '--check');
  expectLinks('1c match: sync --check gives exit 0 and the same lines', c, 0, LEDGER('ok', 'interface "Ledger"'), ROOMS('ok', 'interface "RoomApi"'));
}

// ---- 2. Another interface name on the callee: wrong, exit 1, both names in the message ----
{
  const d = repo({ callee: 'app_link_callee_b' });
  const r = run(d.caller, 'sync');
  expectLinks(
    '2a mismatch: each link is wrong and has the name of the caller and of the callee',
    r,
    1,
    LEDGER('wrong', 'the interfaces differ\\. Caller: "Ledger".*Callee: "LedgerB"'),
    ADMIN('wrong', 'the interfaces differ\\. Caller: "AdminApi".*Callee: "AdminApiB"'),
    ROOMS('wrong', 'the interfaces differ\\. Caller: "RoomApi".*Callee: "RoomApiB"'),
  );
  check('2b mismatch: the message names the config file of each side', /Caller: "Ledger" in wrangler\.json/.test(r.out) && /Callee: "LedgerB" in .*callee\/wrangler\.json/.test(r.out), r.out);
  const c = run(d.caller, 'sync', '--check');
  expectLinks('2c mismatch: sync --check gives exit 1 too', c, 1, LEDGER('wrong', 'the interfaces differ'));
  // One side only: the service goes to the entry point of another interface (the config of ADMIN names Admin, LEDGER the default export).
  const e = repo({ config: callerConfig((c2) => ((c2.services[0].entrypoint = 'Admin'), c2)) });
  const x = run(e.caller, 'sync');
  expectLinks('2d mismatch on the entry point: LEDGER (Ledger) to the entry point Admin (AdminApi) is wrong, the others ok', x, 1, LEDGER('wrong', 'the interfaces differ\\. Caller: "Ledger".*Callee: "AdminApi"'), ADMIN('ok', 'interface "AdminApi"'), ROOMS('ok', 'interface "RoomApi"'));
}

// ---- 3. An entry point or a class that the callee does not have: wrong, exit 1 ----
{
  const d = repo({ config: callerConfig((c) => ((c.services[1].entrypoint = 'Ghost'), c)) });
  const r = run(d.caller, 'sync');
  expectLinks('3a missing entry point: wrong, the message names Ghost and the entry points of the callee', r, 1, ADMIN('wrong', '.*callee/app\\.wasm has no entry point Ghost \\(it has Admin\\)'), LEDGER('ok', 'interface "Ledger"'));
  const e = repo({ config: callerConfig((c) => ((c.durable_objects.bindings[0].class_name = 'Ghost'), c)) });
  const x = run(e.caller, 'sync');
  expectLinks('3b missing class for script_name: wrong, the message names Ghost and the classes of the callee', x, 1, ROOMS('wrong', '.*callee/app\\.wasm has no class Ghost \\(it has Room, Plain\\)'), LEDGER('ok', 'interface "Ledger"'));
}

// ---- 4. What is not a failure: a note, exit 0 ----
{
  // The target Worker is not in the repo: no config with that name.
  const a = repo({ config: callerConfig((c) => ((c.services[0].service = 'nobody'), c)) });
  expectLinks('4a target config not found: a note, the other links are checked, exit 0', run(a.caller, 'sync'), 0, link('note', 'service LEDGER', 'no Wrangler config with name = "nobody" under .*: the link is not checked'), ADMIN('ok', 'interface "AdminApi"'));
  // No `.git` above the caller: the repo root is the caller dir, so the callee is not found.
  const b = repo({ git: false });
  expectLinks('4b no .git: the repo root is the dir of the config, the callee is not found: notes, exit 0', run(b.caller, 'sync'), 0, LEDGER('note', 'no Wrangler config with name = "callee"'), ROOMS('note', 'no Wrangler config with name = "callee"'));
  // The wasm of the target is not built: the note has the build command.
  const c = repo();
  rmSync(join(c.callee, 'app.wasm'));
  writeFileSync(join(c.callee, 'app.roc'), 'app [event!] {}\n');
  const rc = run(c.caller, 'sync');
  expectLinks('4c wasm missing: a note for each link with the build hint, exit 0', rc, 0, LEDGER('note', '.*callee/app\\.wasm \\(of .*callee/wrangler\\.json\\) is not there, so the link is not checked\\. Build it: in .* run roc build --target=wasm32 --no-cache --output=callee/app\\.wasm callee/app\\.roc'), ROOMS('note', '.*is not there'));
  const c2 = repo();
  rmSync(join(c2.callee, 'app.wasm'));
  expectLinks('4d wasm missing and no app.roc: the hint says <its app.roc>', run(c2.caller, 'sync'), 0, LEDGER('note', '.*is not there.*roc build .* <its app\\.roc>'));
  // The wasm is older than a source: a note, and the check still runs on the old wasm.
  const d = repo();
  writeFileSync(join(d.callee, 'app.roc'), 'app [event!] {}\nimport Gavel\n');
  writeFileSync(join(d.callee, 'Gavel.roc'), 'Gavel := {}\n');
  const old = new Date('2026-01-01T00:00:00Z');
  const fresh = new Date('2026-06-01T00:00:00Z');
  utimesSync(join(d.callee, 'app.wasm'), fresh, fresh);
  utimesSync(join(d.callee, 'app.roc'), old, old);
  utimesSync(join(d.callee, 'Gavel.roc'), old, old);
  const upToDate = run(d.caller, 'sync');
  check('4e wasm newer than its sources: no note about it', !/is older than/.test(upToDate.out) && upToDate.code === 0, upToDate.all);
  utimesSync(join(d.callee, 'app.roc'), fresh, fresh);
  utimesSync(join(d.callee, 'app.wasm'), old, old);
  expectLinks('4f stale wasm (app.roc newer): a note with the build hint, and the check still runs, exit 0', run(d.caller, 'sync'), 0, LEDGER('note', '.*callee/app\\.wasm is older than .*callee/app\\.roc: build it again.*roc build --target=wasm32'), LEDGER('ok', 'interface "Ledger"'));
  utimesSync(join(d.callee, 'app.roc'), old, old);
  utimesSync(join(d.callee, 'Gavel.roc'), fresh, fresh);
  expectLinks('4g stale wasm (an imported module newer): the note names that module', run(d.caller, 'sync'), 0, LEDGER('note', '.*is older than .*callee/Gavel\\.roc'));
  // The newer wasm of a mismatch is still wrong: a note does not hide it.
  const s = repo({ callee: 'app_link_callee_b' });
  writeFileSync(join(s.callee, 'app.roc'), 'app [event!] {}\n');
  utimesSync(join(s.callee, 'app.wasm'), old, old);
  utimesSync(join(s.callee, 'app.roc'), fresh, fresh);
  expectLinks('4h stale wasm with another interface name: the note and the wrong line, exit 1', run(s.caller, 'sync'), 1, LEDGER('note', '.*is older than'), LEDGER('wrong', 'the interfaces differ'));
  // The wasm is not an app: the manifest cannot be read.
  const g = repo();
  writeFileSync(join(g.callee, 'app.wasm'), 'not a wasm file');
  expectLinks('4i a wasm that does not load: a note, exit 0', run(g.caller, 'sync'), 0, LEDGER('note', '.*callee/app\\.wasm: no manifest to check'));
}

// ---- 5. Two configs with one name ----
{
  // In one dir, one wasm: the check runs, and there is a note.
  const a = repo();
  writeFileSync(join(a.callee, 'wrangler-b.json'), JSON.stringify({ name: 'callee' }));
  const r = run(a.caller, 'sync');
  expectLinks('5a two configs of one dir with one name, one wasm: a note with both files, the link is checked, exit 0', r, 0, LEDGER('note', '2 Wrangler configs have name = "callee" \\(.*callee/wrangler-b\\.json, .*callee/wrangler\\.json\\)'), LEDGER('ok', 'interface "Ledger"'));
  check('5b the note has no sentence about different wasm files', !/different wasm files/.test(r.out), r.out);
  // In two dirs, two wasm files (one with other names): the link is not checked, so no wrong line, exit 0.
  const b = repo({ callee: 'app_link_callee_b' });
  mkdirSync(join(b.r, 'callee2'));
  copyFileSync(W('app_link_callee'), join(b.r, 'callee2/app.wasm'));
  writeFileSync(join(b.r, 'callee2/wrangler.json'), JSON.stringify({ name: 'callee' }));
  const x = run(b.caller, 'sync');
  expectLinks('5c two configs with one name and two wasm files: a note, the link is not checked, exit 0', x, 0, LEDGER('note', '2 Wrangler configs have name = "callee".*different wasm files, so the link is not checked'));
  check('5d two wasm files: no ok and no wrong link line', !/^ {2}(ok|wrong) +(service|object) /m.test(links(x.out)), links(x.out));
}

// ---- 6. A side with no interface name: nothing to compare, ok ----
{
  const d = repo({ callee: 'app_b3' });
  const r = run(d.caller, 'sync');
  const l = links(r.out);
  check('6a a callee with no Rpc method: the default export link is ok and not compared', /^ {2}ok +service LEDGER -> callee: the default entry point has no Rpc method, so there is no interface to compare/m.test(l), l);
  check('6b the entry point and the class that the callee does not have are still wrong', /^ {2}wrong +service ADMIN .*no entry point Admin \(it has none\)/m.test(l) && /^ {2}wrong +object ROOMS .*no class Room \(it has Counter\)/m.test(l), l);
}

console.log(failed ? 'FAILED' : 'all passed');
process.exit(failed ? 1 : 0);
