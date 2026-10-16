// node conformance/reverts.mjs [name-filter]   (env: ROC; MINIFLARE as run.mjs)
// Revert checks of PLAN.md 8c (wave 1, R2 and Cache) and 8d. Each revert is a real edit of a source file, a build of the conformance app
// into .cache/conformance-reverts/ when a .roc file changed, a run of the test that must catch it, and a restore of the
// file. A change that finds no text to replace is an error (the code moved: update this list).
// The conformance app is on the bench platform, so a Roc edit is in bench/platform/ (the copy of platform/). The MC10
// revert edits platform/Time.roc, which `roc test platform/main.roc` reads. Exit 1 when a revert is not caught.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ROC = process.env.ROC;
if (!ROC) throw new Error('set ROC');
const out = `${root}.cache/conformance-reverts`;
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache` };
const BP = 'bench/platform/';
// The tests. `conformance`: run.mjs, which prints `FAIL <name>`; the others: a command whose exit code is the result.
const TESTS = {
  conformance: () => [process.execPath, ['conformance/run.mjs', `${out}/conformance.wasm`]],
  'roc test': () => [ROC, ['test', 'platform/main.roc']],
  'must-not-compile': () => ['bash', ['conformance/must-not-compile.sh']],
  'handler-test': () => [process.execPath, ['bench/handler-test.mjs', 'bench/out/app.wasm', 'bench/out/app_prod.wasm']],
};
// name, the test, the checks that must fail (conformance only), edits: [file, from, to].
const R = (name, test, checks, ...edits) => ({ name, test, checks, edits });
const reverts = [
  // A wrong JS method name in one function of each module: its route fails.
  R('Http: fetch is called "fetchx"', 'conformance', ['http send!', 'http get!', 'http open!'], [BP + 'Http.roc', 'Call(Root("global"), "fetch",', 'Call(Root("global"), "fetchx",']),
  R('Env.json!: JSON.stringify is called "stringifyx"', 'conformance', ['env json!'], [BP + 'Env.roc', 'Call(Slot(0), "stringify",', 'Call(Slot(0), "stringifyx",']),
  R('Time.sleep: scheduler.wait is called "waitx"', 'conformance', ['time sleep!', 'time sleep (Io twin)', 'time sleep in Io.race!'], [BP + 'Time.roc', 'Call(Slot(0), "wait",', 'Call(Slot(0), "waitx",']),
  R('Time.now_ms!: Date.now is called "nowx"', 'conformance', ['time now_ms!'], [BP + 'Time.roc', 'Call(Slot(0), "now", [])', 'Call(Slot(0), "nowx", [])']),
  R('Log.info!: console.info is called "infox"', 'conformance', ['log info!'], [BP + 'Log.roc', 'write!("info", line(', 'write!("infox", line(']),
  R('RateLimit.limit: the binding method is called "limitx"', 'conformance', ['ratelimit limit!', 'ratelimit limit (Io twin)'], [BP + 'RateLimit.roc', 'Call(Slot(0), "limit",', 'Call(Slot(0), "limitx",']),
  // PLAN.md 8d.
  R('Http: no map (HttpErr for each throw)', 'conformance', ['http 8d: a closed port is Network', 'http 8d: a host that does not exist is Network', 'http send_with! timeout_ms'],
    [BP + 'Http.roc', '} else if t.name == "TypeError" {', '} else if Bool.True {']),
  R('Http: map by the message "Network connection lost" only', 'conformance', ['http 8d: a host that does not exist is Network'],
    [BP + 'Http.roc', '} else if t.name == "TypeError" {', '} else if !t.message.contains("Network connection lost") {']),
  // PLAN.md 8c: Request.Cf.
  R('Request.Cf: the shim reads null as an empty text', 'conformance', ['request cf: colo Ok, a field that is not set Err(Missing)'],
    ['js/events.js', 'for (const [name, js, ok] of CF) out[name] = ok(cf[js]) ? { Ok: cf[js] } : MISSING;', "for (const [name, js, ok] of CF) out[name] = ok === isText && cf[js] == null ? { Ok: '' } : ok(cf[js]) ? { Ok: cf[js] } : MISSING;"]),
  // PLAN.md 8c: the MC10 conversion rounds down.
  R('Time.seconds_up rounds down', 'roc test', [], ['platform/Time.roc', 'seconds_up = |ms| ms // 1000 + (if ms % 1000 > 0 1 else 0)', 'seconds_up = |ms| ms // 1000']),
  // MODULES.md 10: a Secret over a bare Str gets the codecs of Str (roc-lang/roc#12309).
  R('Secret :: Str', 'must-not-compile', [], [BP + 'Secret.roc', 'Secret :: { text : Str }.{', 'Secret :: Str.{'], [BP + 'Secret.roc', 'from_str = |text| Secret.{ text }', 'from_str = |text| Secret.(text)'],
    [BP + 'Secret.roc', 'reveal = |s| s.text', 'reveal = |s| match s {\n\t\tSecret.(t) => t\n\t}']),
  // PLAN.md 8a O4: the old check of `ops` (functions only).
  R('ops: functions only', 'conformance', ['start'], ['js/options.js', "Object.values(v).every(isOp)", 'Object.values(v).every(isFn)']),
  R('ops: functions only (handler-test)', 'handler-test', [], ['js/options.js', "Object.values(v).every(isOp)", 'Object.values(v).every(isFn)']),
  // A null body (204) is no bytes in pf.readUpTo.
  R('readUpTo: no null branch', 'conformance', ['http send! of a 204 (no body)'], ['js/helpers.js', '      if (stream === null) return new Uint8Array(0);\n', '']),
  // PLAN.md 8c, R2 and Cache. A wrong JS method name in one function: its route fails.
  R('R2.head: head is called "headx"', 'conformance', ['r2 head!', 'r2 head (Io twin)'], [BP + 'R2.roc', 'call_ops(bucket, "head",', 'call_ops(bucket, "headx",']),
  R('R2.get: get is called "getx"', 'conformance', ['r2 get!', 'r2 get (Io twin)'], [BP + 'R2.roc', 'call_ops(bucket, "get", [Lit(Text(key))], [])', 'call_ops(bucket, "getx", [Lit(Text(key))], [])']),
  R('R2.list: pf.r2list is called "r2listx"', 'conformance', ['r2 list! start_after', 'r2 list! limit, cursor, delimiter'], [BP + 'R2.roc', 'Call(Root("pf"), "r2list",', 'Call(Root("pf"), "r2listx",']),
  R('Cache.get: match is called "matchx"', 'conformance', ['cache get! of a missing key is NotFound', 'cache put! and get!'], [BP + 'Cache.roc', 'Call(Slot(1), "match",', 'Call(Slot(1), "matchx",']),
  // OP7: Get and Fields on null and undefined throw: a missing key is R2Err and CacheErr, not NotFound.
  R('OP7: no ?. in Get and Fields (js/program.js)', 'conformance', ['r2 get! of a missing key is NotFound', 'r2 head! of a missing key is NotFound', 'cache get! of a missing key is NotFound'],
    ['js/program.js', 'return o === null || o === undefined ? undefined : o[name];', 'return o[name];'],
    ['js/program.js', 'if (o === null || o === undefined) return undefined; // OP7', '']),
  // R2.Cond: the module sends only the first field.
  R('R2.put_with: only_if sends only the first field', 'conformance', ['r2 put_with! only_if with two fields'],
    [BP + 'R2.roc', '\t\t|> put_date("uploadedBefore", c.?uploaded_before_ms)\n\t\t|> put_date("uploadedAfter", c.?uploaded_after_ms)\n', '']),
  R('R2.put_with: only_if is not sent', 'conformance', ['r2 put_with! only_if: a wrong etag_matches is PreconditionFailed', 'r2 put_with! absent: a key that exists is PreconditionFailed'],
    [BP + 'R2.roc', 'Ok(c) => put_record(build(base), "onlyIf", finish(cond_build(c, base)))', 'Ok(_) => build(base)']),
  // Multipart: each function of Upload calls createMultipartUpload in place of resumeMultipartUpload.
  R('R2.Upload: createMultipartUpload in place of resumeMultipartUpload', 'conformance', ['r2 multipart: create, upload_part, complete in three requests'],
    [BP + 'R2.roc', 'Call(Slot(0), "resumeMultipartUpload", [Lit(Text(up.key))', 'Call(Slot(0), "createMultipartUpload", [Lit(Text(up.key))']),
  // A stream with no known length: no FixedLengthStream.
  R('R2.put_with: no FixedLengthStream', 'conformance', ['r2 put_with! of a stream with length_bytes stores the bytes'],
    [BP + 'R2.roc', '\tStream(r) => match length {\n\t\tOk(n) => {', '\tStream(r) => match length {\n\t\tOk(_) => { ops: [], arg: Lit(Ref(r)) }\n\t\tOk(n) => {']),
  R('R2.list: include is not sent', 'conformance', ['r2 put_with! http: head! has it, list! has none, list! with include has it', 'r2 put_with! custom, list! include Custom'],
    [BP + 'R2.roc', '("include", Arr(inc.map(', '("includex", Arr(inc.map(']),
  R('R2.list: start_after is not sent', 'conformance', ['r2 list! start_after'], [BP + 'R2.roc', '("startAfter", Text(s))', '("startAfterx", Text(s))']),
  R('R2.get_with: the module does not read range', 'conformance', ['r2 get_with! range From', 'r2 get_with! range Suffix'],
    [BP + 'R2.roc', 'match range_of(field(got.fields, "range")) {', 'match Err(NoRange) {']),
  R('R2.put_with: the checksum is not sent', 'conformance', ['r2 put_with! checksum: a wrong Sha256 is R2Err, the right one is in meta.checksums'],
    [BP + 'R2.roc', 'Ok(Sha256(b)) => put_lit(b3, "sha256", Bytes(b))', 'Ok(Sha256(_)) => b3']),
  R('R2.Meta: md5 is not read', 'conformance', ['r2 put! with no checksum has an MD5'], [BP + 'R2.roc', 'Bytes(b) => { ..c0, md5: b }', 'Bytes(_) => c0']),
  R('Cache.put: the status is always 200', 'conformance', ['cache put! of a 206 response is CacheErr'], [BP + 'Cache.roc', '("status", Lit(Int(res.status.to_i64()))),', '("status", Lit(Int(200))),']),
  R('Cache.delete: false is Ok', 'conformance', ['cache delete! of a key that is not cached is NotFound'],
    [BP + 'Cache.roc', 'Ok(Bool(Bool.False)) => Err(NotFound)', 'Ok(Bool(Bool.False)) => Ok({})']),
  // 10a with R2: the body is read into wasm before the response.
  R('10a: the R2 body is copied into wasm (conformance/R2Routes.roc)', 'conformance', ['r2 10a: a 50 MB object through get! to the response, wasm memory grows by less than 1 MB'],
    ['conformance/R2Routes.roc', 'Ok(obj) => Response.from_body(200, "application/octet-stream", obj.body)\n\tErr(e) => Response.from_text(200, "Err ${Str.inspect(e)}")\n}', 'Ok(obj) => match obj.body.bytes_with!({ max_bytes: 100_000_000 }) {\n\t\tOk(b) => Response.from_bytes(200, "application/octet-stream", b)\n\t\tErr(e) => Response.from_text(200, "Err ${Str.inspect(e)}")\n\t}\n\tErr(e) => Response.from_text(200, "Err ${Str.inspect(e)}")\n}']),
];

const filter = process.argv[2];
const sh = (cmd, args) => spawnSync(cmd, args, { cwd: root, env, encoding: 'utf8', timeout: 600000 });
const build = () => {
  mkdirSync(out, { recursive: true });
  const r = sh(ROC, ['build', '--opt=speed', '--target=wasm32', '--no-cache', `--output=${out}/conformance.wasm`, 'conformance/app.roc']);
  return r.status === 0 || r.status === 2 ? null : `roc build failed: ${(r.stdout + r.stderr).slice(-400)}`;
};
const test = (name) => {
  const [cmd, args] = TESTS[name]();
  const r = sh(cmd, args);
  const text = r.stdout + r.stderr;
  return { pass: r.status === 0, lines: text.split('\n').filter((l) => l.startsWith('FAIL ')), text };
};

let bad = false;
const cleanBuild = build();
if (cleanBuild) {
  console.log(`the clean tree: ${cleanBuild}`);
  process.exit(1);
}
for (const name of Object.keys(TESTS)) {
  const c = test(name);
  if (!c.pass) {
    console.log(`the clean tree fails ${name}: ${c.text.slice(-600)}`);
    process.exit(1);
  }
}
console.log('clean tree: PASS');
let built = true;
for (const rv of reverts) {
  if (filter && !rv.name.includes(filter)) continue;
  const saved = new Map();
  try {
    for (const [f, from, to] of rv.edits) {
      if (!saved.has(f)) saved.set(f, readFileSync(root + f, 'utf8'));
      const s = readFileSync(root + f, 'utf8');
      if (!s.includes(from)) throw new Error(`no text to replace in ${f}: ${from.slice(0, 60)}`);
      writeFileSync(root + f, s.replace(from, to));
    }
    const roc = rv.edits.some(([f]) => f.endsWith('.roc'));
    if (rv.test === 'conformance' && (roc || !built)) {
      const err = build();
      if (err) {
        console.log(`${rv.name}: ${err}`);
        bad = true;
        continue;
      }
      built = !roc;
    }
    const t = test(rv.test);
    const caught = !t.pass && rv.checks.every((c) => t.lines.some((l) => l.startsWith(`FAIL ${c}: `)));
    const where = rv.test === 'conformance' ? `${t.lines.length} checks FAIL` : `${rv.test} FAILED`;
    console.log(`${rv.name}: ${t.pass ? `NOT CAUGHT (${rv.test} passed)` : where}${caught || t.pass ? '' : `, but not in all of [${rv.checks.join('; ')}]`}`);
    const line = t.text.split('\n').find((l) => l.startsWith('FAIL') || l.includes('✗') || l.includes('FAIL'));
    if (line) console.log(`  first: ${line.slice(0, 240)}`);
    if (!caught) bad = true;
  } finally {
    for (const [f, text] of saved) writeFileSync(root + f, text);
  }
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
