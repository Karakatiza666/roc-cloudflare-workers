// node conformance/reverts.mjs [name-filter]   (env: ROC; MINIFLARE as run.mjs)
// Revert checks of PLAN.md 8c (wave 1, WebCrypto, R2 and Cache, D1, Sql and Memo), 8d, and 8f (part 1: Objects, RPC, Manifest; part 2: Queue, Kv, Email, Tail; part 3: WebSocket, Tcp; part 4: other bindings). Each revert is a real edit of a source file, a build of the conformance app
// into .cache/conformance-reverts/ when a .roc file changed, a run of the test that must catch it, and a restore of the
// file. A change that finds no text to replace is an error (the code moved: update this list).
// The conformance app is on the bench platform, so a Roc edit is in bench/platform/ (the copy of platform/). The MC10
// revert edits platform/Time.roc, which `roc test platform/main.roc` reads. Exit 1 when a revert is not caught.
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ROC = process.env.ROC;
if (!ROC) throw new Error('set ROC');
const out = `${root}.cache/conformance-reverts`;
const env = { ...process.env, ROC_CACHE_DIR: `${root}.cache/roc`, XDG_CACHE_HOME: `${root}.cache` };
// The temp dirs of conformance runs that are not alive (`run.mjs` makes `.cache/tmp/run-<pid>`; a run killed with SIGKILL
// leaves its dir).
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
};
mkdirSync(`${root}.cache/tmp`, { recursive: true });
for (const d of readdirSync(`${root}.cache/tmp`)) {
  const m = /^run-(\d+)$/.exec(d);
  if (m && !alive(Number(m[1]))) rmSync(`${root}.cache/tmp/${d}`, { recursive: true, force: true });
}
const BP = 'bench/platform/';
const IX = 'js/index.js';
// The roc-cbor 0.2.0 package in the cache of the build (XDG_CACHE_HOME=.cache): a revert of `Cbor.Bytes` edits it.
const CBOR = '.cache/roc/packages/GTUNBR1419Xvgw1eightgb14scrrWkoiTVkBPJ94yHMA/Cbor.roc';
// The tests. `conformance`: run.mjs, which prints `FAIL <name>`; the others: a command whose exit code is the result.
const TESTS = {
  conformance: () => [process.execPath, ['conformance/run.mjs', `${out}/conformance.wasm`]],
  'roc test': () => [ROC, ['test', 'platform/main.roc']],
  'must-not-compile': () => ['bash', ['conformance/must-not-compile.sh']],
  'handler-test': () => [process.execPath, ['bench/handler-test.mjs', 'bench/out/app.wasm', 'bench/out/app_prod.wasm']],
  'layout-test': () => [process.execPath, ['bench/layout-test.mjs', 'bench/out/app.wasm']],
  'entry-test': () => [process.execPath, ['bench/entry-test.mjs', 'bench/out/app_events.wasm']],
  'program-test': () => [process.execPath, ['bench/program-test.mjs']],
  'bindings-test': () => [process.execPath, ['bench/bindings-test.mjs', 'bench/out']],
  'cli-test': () => [process.execPath, ['bench/cli-test.mjs', 'bench/out']],
  // The build of the conformance app only (exit 2: warnings only), for a revert that crashes the compiler.
  'conformance build': () => ['bash', ['-c', '"$ROC" build --opt=speed --target=wasm32 --no-cache --output=.cache/conformance-reverts/build-check.wasm conformance/app.roc || [ $? -eq 2 ]']],
};
// name, the test, the checks that must fail (conformance only), edits: [file, from, to].
const R = (name, test, checks, ...edits) => ({ name, test, checks, edits });
const reverts = [
  // 8h wave C: the builders of the opaque Request and Response (one route, `/http/builders`).
  R('Response.with_status: keeps the status', 'conformance', ['http wave C builders: Request.new with_body, with_method, with_url, and Response.with_status, with_body'], [BP + 'Response.roc', 'with_status = |r, code| { ..r, status: code }', 'with_status = |r, _code| r']),
  R('Request.with_body: keeps the body', 'conformance', ['http wave C builders: Request.new with_body, with_method, with_url, and Response.with_status, with_body'], [BP + 'Request.roc', 'with_body = |r, b| { ..r, body: b }', 'with_body = |r, _b| r']),
  R('Request.with_url: keeps the url', 'conformance', ['http wave C builders: Request.new with_body, with_method, with_url, and Response.with_status, with_body'], [BP + 'Request.roc', 'with_url = |r, u| { ..r, url: u }', 'with_url = |r, _u| r']),
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
  // PLAN.md 8c, WebCrypto: a wrong JS method name in one function, then the reverts of the tests.
  R('WebCrypto.sign: subtle.sign is called "signx"', 'conformance', ['webcrypto generate_key! Ed25519, sign! and verify!', 'webcrypto sign! RS256 with a PKCS#8 key', 'webcrypto sign! and verify! HMAC-SHA256, hmac_sha256'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "sign", [', 'Call(Slot(1), "signx", [']),
  R('WebCrypto.verify: subtle.verify is called "verifyx"', 'conformance', ['webcrypto generate_key! Ed25519, sign! and verify!', 'webcrypto verify! RS256 of a JWT with a JWK (one crossing)'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "verify", [', 'Call(Slot(1), "verifyx", [']),
  R('WebCrypto.encrypt: subtle.encrypt is called "encryptx"', 'conformance', ['webcrypto RsaOaep encrypt! and decrypt!', 'webcrypto AesGcm, AesCbc, AesCtr encrypt! and decrypt!', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "encrypt", [', 'Call(Slot(1), "encryptx", [']),
  R('WebCrypto.decrypt: subtle.decrypt is called "decryptx"', 'conformance', ['webcrypto RsaOaep encrypt! and decrypt!', 'webcrypto AesGcm, AesCbc, AesCtr encrypt! and decrypt!', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "decrypt", [', 'Call(Slot(1), "decryptx", [']),
  R('WebCrypto.derive_bits: subtle.deriveBits is called "deriveBitsx"', 'conformance', ['webcrypto derive_bits! Ecdh(P256), both sides', 'webcrypto derive_bits! X25519, both sides'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "deriveBits", [', 'Call(Slot(1), "deriveBitsx", [']),
  R('WebCrypto.import_key: subtle.importKey is called "importKeyx"', 'conformance', ['webcrypto export_key! of import_key! of Raw(b)', 'webcrypto sign! and verify! HMAC-SHA256, hmac_sha256'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "importKey", args("raw"', 'Call(Slot(1), "importKeyx", args("raw"']),
  R('WebCrypto.import_key: JSON.parse of a JWK is called "parsex"', 'conformance', ['webcrypto verify! RS256 of a JWT with a JWK (one crossing)', 'webcrypto import_key! of a private and a public JWK'], [BP + 'WebCrypto.roc', 'Call(Slot(n), "parse", [Lit(Text(text))])', 'Call(Slot(n), "parsex", [Lit(Text(text))])']),
  R('WebCrypto.export_key: subtle.exportKey is called "exportKeyx"', 'conformance', ['webcrypto export_key! of import_key! of Raw(b)', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "exportKey", [Lit(Text(form_name(form))), Lit(Ref(ref))]),', 'Call(Slot(1), "exportKeyx", [Lit(Text(form_name(form))), Lit(Ref(ref))]),']),
  R('WebCrypto.export_key: JSON.stringify of a JWK is called "stringifyx"', 'conformance', ['webcrypto export_key! of import_key! of Raw(b)'], [BP + 'WebCrypto.roc', 'Call(Slot(3), "stringify", [Slot(2)])', 'Call(Slot(3), "stringifyx", [Slot(2)])']),
  R('WebCrypto.generate_key: subtle.generateKey is called "generateKeyx"', 'conformance', ['webcrypto generate_key! Ed25519, sign! and verify!', 'webcrypto RsaOaep encrypt! and decrypt!', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', 'Call(Slot(1), "generateKey", [', 'Call(Slot(1), "generateKeyx", [']),
  R('WebCrypto.timing_safe_equal!: subtle.timingSafeEqual is called "timingSafeEqualx"', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)', 'webcrypto sign! and verify! HMAC-SHA256, hmac_sha256'], [BP + 'WebCrypto.roc', '"timingSafeEqual"', '"timingSafeEqualx"']),
  R('WebCrypto.random!: getRandomValues is called "getRandomValuesx"', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', '"getRandomValues"', '"getRandomValuesx"']),
  R('WebCrypto.random_uuid!: randomUUID is called "randomUUIDx"', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', '"randomUUID"', '"randomUUIDx"']),
  // The tests of PLAN.md 8c.
  R('WebCrypto.derive_bits!: Ecdh derives with the key of the app as the peer key', 'conformance', ['webcrypto derive_bits! Ecdh(P256), both sides'], [BP + 'WebCrypto.roc', 'Ecdh({ curve, public }) => with_peer(ops, public,', 'Ecdh({ curve, public: _ }) => with_peer(ops, a.key,']),
  R('WebCrypto.derive_bits!: X25519 derives with the key of the app as the peer key', 'conformance', ['webcrypto derive_bits! X25519, both sides'], [BP + 'WebCrypto.roc', 'X25519({ public }) => with_peer(ops, public,', 'X25519({ public: _ }) => with_peer(ops, a.key,']),
  R('WebCrypto.verify!: a signature that does not match is Ok', 'conformance', ['webcrypto generate_key! Ed25519, sign! and verify!', 'webcrypto verify! with a JWK: a wrong signature, a wrong text', 'webcrypto sign! and verify! HMAC-SHA256, hmac_sha256'], [BP + 'WebCrypto.roc', 'Ok(Bool(ok)) => if ok Ok({}) else Err(BadSignature)', 'Ok(Bool(ok)) => if Bool.True Ok({}) else Err(BadSignature)']),
  R('WebCrypto.encrypt!: the data is reversed before the encrypt', 'conformance', ['webcrypto RsaOaep encrypt! and decrypt!', 'webcrypto AesGcm, AesCbc, AesCtr encrypt! and decrypt!', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', '"encrypt", [Lit(cipher_algo(a.cipher)), arg_of(key), Lit(Bytes(a.data))]', '"encrypt", [Lit(cipher_algo(a.cipher)), arg_of(key), Lit(Bytes(a.data.rev()))]']),
  R('WebCrypto.export_key!: Raw reads the bytes reversed', 'conformance', ['webcrypto export_key! of import_key! of Raw(b)'], [BP + 'WebCrypto.roc', '(Ok(Bytes(b)), Raw) => Ok(Raw(b))', '(Ok(Bytes(b)), Raw) => Ok(Raw(b.rev()))']),
  R('WebCrypto.decrypt!: call! in place of await! (status 2)', 'conformance', ['webcrypto RsaOaep encrypt! and decrypt!', 'webcrypto AesGcm, AesCbc, AesCtr encrypt! and decrypt!', 'webcrypto Io twins'], [BP + 'WebCrypto.roc', 'Io.new(ops.append(Call(Slot(1), "decrypt",', 'Io.sync(ops.append(Call(Slot(1), "decrypt",']),
  R('WebCrypto.timing_safe_equal!: await! in place of call!', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', 'match Io.call!([Get(Root("global"), "crypto"), Get(Slot(0), "subtle"), Call(Slot(1), "timingSafeEqual"', 'match Io.await!([Get(Root("global"), "crypto"), Get(Slot(0), "subtle"), Call(Slot(1), "timingSafeEqual"']),
  R('WebCrypto.random!: await! in place of call!', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', 'got = match Io.call!(', 'got = match Io.await!(']),
  R('WebCrypto.random_uuid!: await! in place of call!', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', 'match Io.call!([Get(Root("global"), "crypto"), Call(Slot(0), "randomUUID"', 'match Io.await!([Get(Root("global"), "crypto"), Call(Slot(0), "randomUUID"']),
  R('WebCrypto.random!: no chunks of 65,536 bytes', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)'], [BP + 'WebCrypto.roc', 'chunk = if n > 65_536 65_536 else n', 'chunk = n']),
  R('WebCrypto.verify!: import_key! first, then verify! (two crossings)', 'conformance', ['webcrypto verify! RS256 of a JWT with a JWK (one crossing)'],
    [BP + 'WebCrypto.roc', 'verify! = |a| Io.run!(verify(a))', 'verify! = |a| {\n\t\tka : WebCrypto.KeyAlg\n\t\tka = match a.alg {\n\t\t\tRsaPkcs1(h) => RsaPkcs1(h)\n\t\t\t_ => Ed25519\n\t\t}\n\t\tmatch Io.run!(import_key(ka, a.key)) {\n\t\t\tOk(key) => Io.run!(verify({ ..a, key }))\n\t\t\tErr(e) => Err(e)\n\t\t}\n\t}']),
  R('WebCrypto.import_key!: a JWK is never private (the usages are verify)', 'conformance', ['webcrypto import_key! of a private and a public JWK'], [BP + 'WebCrypto.roc', 'parsed.is_ok()', 'Bool.False']),
  R('Js pins: pf.pin does not keep the value', 'conformance', ['webcrypto a pinned CryptoKey used by a later request'], ['js/helpers.js', '      shim.pins.pin(name, value, maxAgeMs);\n', '']),
  R('WebCrypto.hmac_sha256: the inner pad uses 0x5c', 'roc test', [], ['platform/WebCrypto.roc', 'bitwise_xor(0x36)', 'bitwise_xor(0x5c)']),
  // Id64 (MODULES.md 5.1): the CBOR form is the I64 text; the JSON gate is the `encode_bytes` and `parse_bytes` markers; `Web` reads text only.
  R('Id64.to_str gives the U64 text', 'conformance', ['d1 Id64'], [BP + 'Id64.roc', 'to_str = |id| id.bits.to_str()', 'to_str = |id| id.bits.to_u64_wrap().to_str()']),
  R('Id64 CBOR encoder writes the U64 text (an Id64 SQL parameter above 2^63 is not stored exact)', 'conformance', ['d1 Id64'], [BP + 'Id64.roc', '|id, state| Encoding.encode_str(id.bits.to_str(), state)', '|id, state| Encoding.encode_str(id.bits.to_u64_wrap().to_str(), state)']),
  R('Id64.from_u64 loses the top bit', 'roc test', [], ['platform/Id64.roc', 'Id64.{ bits: n.to_i64_wrap() }', 'Id64.{ bits: n.bitwise_and(0x7FFF_FFFF_FFFF_FFFF).to_i64_wrap() }']),
  R('Id64.Web writes the I64 text', 'roc test', [], ['platform/Id64.roc', 'Encoding.encode_str(w.bits.to_u64_wrap().to_str(), state)', 'Encoding.encode_str(w.bits.to_str(), state)']),
  R('Id64 encoder: no encode_bytes marker (bare Id64 compiles in JSON)', 'must-not-compile', [], [BP + 'Id64.roc', '\t\t\tencoding.encode_bytes : List(U8), state -> Try(state, err),\n\t\t]\n\tencoder_for = |_| {\n\t\tEncoding : encoding\n\n\t\t|id, state|', '\t\t]\n\tencoder_for = |_| {\n\t\tEncoding : encoding\n\n\t\t|id, state|']),
  R('Id64 parser: no parse_bytes marker (a JSON number reads as an id)', 'must-not-compile', [], [BP + 'Id64.roc', '\t\t\tencoding.parse_bytes : encoding, state -> Try({ value : List(U8), rest : state }, err),\n', '']),
  R('WebCrypto.hmac_sha256: a key longer than the block is not hashed', 'roc test', [], ['platform/WebCrypto.roc', 'if key.len() > block Crypto', 'if key.len() > 100_000 Crypto']),
  // PLAN.md 8g P2: `WebCrypto.sha256!` picks the builtin below 4,096 bytes and `crypto.subtle.digest` from there.
  R('WebCrypto.sha256!: always the builtin (no crossing at 1 MB)', 'conformance', ['webcrypto sha256!: the digest of Node, 0 crossings below 4,096 bytes and 1 above', 'webcrypto sha256 (Io twin): the digest of Node, a wait above 4,096 bytes only'], [BP + 'WebCrypto.roc', 'bytes.len() < sha256_crossover_bytes', 'Bool.True']),
  R('WebCrypto.sha256!: always digest (a crossing at 1 KB)', 'conformance', ['webcrypto sha256!: the digest of Node, 0 crossings below 4,096 bytes and 1 above', 'webcrypto sha256 (Io twin): the digest of Node, a wait above 4,096 bytes only'], [BP + 'WebCrypto.roc', 'bytes.len() < sha256_crossover_bytes', 'Bool.False']),
  R('WebCrypto.sha256!: the wrong side of the crossover', 'conformance', ['webcrypto sha256!: the digest of Node, 0 crossings below 4,096 bytes and 1 above', 'webcrypto sha256 (Io twin): the digest of Node, a wait above 4,096 bytes only'], [BP + 'WebCrypto.roc', 'bytes.len() < sha256_crossover_bytes', 'bytes.len() >= sha256_crossover_bytes']),
  R('WebCrypto.sha256!: the crossover size itself is the builtin side', 'conformance', ['webcrypto sha256!: the digest of Node, 0 crossings below 4,096 bytes and 1 above', 'webcrypto sha256 (Io twin): the digest of Node, a wait above 4,096 bytes only'], [BP + 'WebCrypto.roc', 'bytes.len() < sha256_crossover_bytes', 'bytes.len() <= sha256_crossover_bytes']),
  R('WebCrypto.sha256_crossover_bytes is 4,097', 'roc test', [], ['platform/WebCrypto.roc', 'sha256_crossover_bytes = 4_096', 'sha256_crossover_bytes = 4_097']),
  R('WebCrypto.sha256_crossover_bytes is 4,095', 'roc test', [], ['platform/WebCrypto.roc', 'sha256_crossover_bytes = 4_096', 'sha256_crossover_bytes = 4_095']),
  // The old local value (2,700): the conformance check sees a crossing at 4,095 bytes.
  R('WebCrypto.sha256_crossover_bytes is the local value 2,700', 'conformance', ['webcrypto sha256!: the digest of Node, 0 crossings below 4,096 bytes and 1 above', 'webcrypto sha256 (Io twin): the digest of Node, a wait above 4,096 bytes only'], [BP + 'WebCrypto.roc', 'sha256_crossover_bytes = 4_096', 'sha256_crossover_bytes = 2_700']),
  // PLAN.md EP10: no incomplete multipart upload stays in the bucket. The helper `uploads` of checks/r2.mjs, and the routes of R2Routes.roc.
  R('R2 checks: the helper aborts no upload', 'conformance', ['r2 multipart: an upload of a check that fails is aborted', 'r2 multipart: no upload is open after the checks'], ['conformance/checks/r2.mjs', 'for (const upload of noted) await', 'for (const upload of []) await']),
  R('R2 checks: the helper aborts only after a pass (no finally)', 'conformance', ['r2 multipart: an upload of a check that fails is aborted'], ['conformance/checks/r2.mjs', '    return await body((upload) => (noted.push(upload), upload));\n  } finally {\n    await abortAll();\n  }', '    const r = await body((upload) => (noted.push(upload), upload));\n    await abortAll();\n    return r;\n  } catch (e) {\n    throw e;\n  }']),
  R('R2Routes mp_create: a refused part does not abort the upload', 'conformance', ['r2 multipart: no upload is open after the checks'], ['conformance/R2Routes.roc', 'so the upload is aborted here.\n\t\t\t\tErr(e) => {\n\t\t\t\t\t_aborted = up.abort!()', 'so the upload is aborted here.\n\t\t\t\tErr(e) => {\n\t\t\t\t\t_aborted = Ok({})']),
  R('R2Routes mp_with: a refused part does not abort the upload', 'conformance', ['r2 multipart: no upload is open after the checks'], ['conformance/R2Routes.roc', 'Ok(up) => match up.upload_part!(number, Text("last part")) {\n\t\t\tErr(e) => {\n\t\t\t\t_aborted = up.abort!()', 'Ok(up) => match up.upload_part!(number, Text("last part")) {\n\t\t\tErr(e) => {\n\t\t\t\t_aborted = Ok({})']),
  R('R2Routes mp_with: a failed complete does not abort the upload', 'conformance', ['r2 multipart: no upload is open after the checks'], ['conformance/R2Routes.roc', 'if done.is_err() {\n\t\t\t\t\t_aborted = up.abort!()', 'if done.is_err() {\n\t\t\t\t\t_aborted = Ok({})']),
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
    [BP + 'R2.roc', 'Ok(c) => put_record(build(base), "onlyIf", cond_ops(c, base))', 'Ok(_) => build(base)']),
  // MODULES.md 5.3 and 12.1: R2 conditional headers, to_response, respond!, and Object broadcast.
  R('R2.cond_ops: the headers of the condition are dropped', 'conformance', ['r2 get_with! of R2.from_headers: a failed If-Match is PreconditionFailed, a right one and no header are Ok', 'r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body'], [BP + 'R2.roc', 'Ok(headers) => { ops: [New(Root("global"), "Headers", [Lit(Obj(conditional_headers(headers)))])], slot: base }', 'Ok(_) => finish(cond_build(c, base))']),
  R('R2.from_headers: gives no headers', 'conformance', ['r2 get_with! of R2.from_headers: a failed If-Match is PreconditionFailed, a right one and no header are Ok'], [BP + 'R2.roc', 'from_headers = |headers| { headers: headers }', 'from_headers = |_headers| {}']),
  R('R2.conditional_headers: If-None-Match is not sent', 'conformance', ['r2 get_with! of R2.from_headers: a failed If-Match is PreconditionFailed, a right one and no header are Ok', 'r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body'], [BP + 'R2.roc', '["if-match", "if-none-match", "if-modified-since", "if-unmodified-since"]', '["if-match", "if-modified-since", "if-unmodified-since"]']),
  R('R2.respond: no 304 branch (always 412)', 'conformance', ['r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body', 'r2 respond!: If-Modified-Since after the upload is 304, before it is 200'], [BP + 'R2.roc', 'Response.{ status: if asks_change 304 else 412,', 'Response.{ status: 412,']),
  R('R2.respond: 304 and 412 swapped', 'conformance', ['r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body', 'r2 respond!: If-Match with another etag is 412 (not 304), with the right etag is 200'], [BP + 'R2.roc', 'Response.{ status: if asks_change 304 else 412,', 'Response.{ status: if asks_change 412 else 304,']),
  R('R2.respond: a 304 or 412 has every header of the object', 'conformance', ['r2 respond!: If-None-Match with the etag is 304 with etag, cache-control and expires, and no body'], [BP + 'R2.roc', 'meta_headers(meta).keep_if(|h| h.name == "etag" or h.name == "cache-control" or h.name == "expires")', 'meta_headers(meta)']),
  R('R2.respond: no accept-ranges header', 'conformance', ['r2 respond!: 200 with the metadata, etag and accept-ranges', 'r2 respond!: one range is 206 with content-range and the bytes (a-b, a-, -n, past the end)'], [BP + 'R2.roc', 'meta_headers(obj.meta).append(Header.{ name: "accept-ranges", value: "bytes" })', 'meta_headers(obj.meta)']),
  R('R2.respond: a range a-b is one byte short', 'conformance', ['r2 respond!: one range is 206 with content-range and the bytes (a-b, a-, -n, past the end)'], [BP + 'R2.roc', 'length_bytes: b - a + 1 }', 'length_bytes: b - a }']),
  R('R2.range_span: a suffix range ends after the last byte', 'conformance', ['r2 respond!: one range is 206 with content-range and the bytes (a-b, a-, -n, past the end)'], [BP + 'R2.roc', 'Ok({ first: size - U64.min(n, size), last: size - 1 })', 'Ok({ first: size - U64.min(n, size), last: size })']),
  R('R2.respond: the range of the request is not sent to R2', 'conformance', ['r2 respond!: one range is 206 with content-range and the bytes (a-b, a-, -n, past the end)'], [BP + 'R2.roc', 'Ok(range) => { ..opts0, range }', 'Ok(_) => opts0']),
  R('R2.respond: If-Range does not give the whole object', 'conformance', ['r2 respond!: more than one range, a wrong range and If-Range give 200 with the whole object'], [BP + 'R2.roc', '(Err(_), Ok(text)) => parse_range(text)', '(_, Ok(text)) => parse_range(text)']),
  R('R2.respond!: the 416 of the error 10039 has no content-range', 'conformance', ['r2 respond!: a range after the end is 416 (R2 error 10039)'], [BP + 'R2.roc', 'Ok(meta) => Ok({ ..res, headers: [Header.{ name: "content-range", value: "bytes */${meta.size_bytes.to_str()}" }] })', 'Ok(_) => Ok(res)']),
  R('R2.respond: no 416 mapping of the R2 error 10039', 'conformance', ['r2 respond!: a range after the end is 416 (R2 error 10039)'], [BP + 'R2.roc', 'if t.message.contains("(10039)") Ok(Response.from_status(416)) else Err(R2Err(t))', 'Err(R2Err(t))']),
  R('R2.respond: a missing key is 200', 'conformance', ['r2 respond!: a key that is not there is 404 "Not found"'], [BP + 'R2.roc', 'Ok(Absent) => Ok(Response.from_text(404, "Not found"))', 'Ok(Absent) => Ok(Response.from_text(200, "Not found"))']),
  R('R2.to_response: no etag header', 'conformance', ['r2 to_response: 200, the metadata and etag, a missing metadata field is not set', 'r2 respond!: 200 with the metadata, etag and accept-ranges'], [BP + 'R2.roc', '("etag", Ok(meta.http_etag)),', '']),
  R('R2.to_response: no expires header', 'conformance', ['r2 to_response: 200, the metadata and etag, a missing metadata field is not set', 'r2 respond!: 200 with the metadata, etag and accept-ranges'], [BP + 'R2.roc', '("expires", h.?cache_expiry_ms.map_ok(http_date)),', '']),
  R('R2.http_date: the weekday is wrong', 'conformance', ['r2 to_response: 200, the metadata and etag, a missing metadata field is not set'], [BP + 'R2.roc', '.get((days % 7).to_u64())', '.get(((days + 1) % 7).to_u64())']),
  R('R2.to_response: a missing metadata field is set to a default', 'conformance', ['r2 to_response: 200, the metadata and etag, a missing metadata field is not set'], [BP + 'R2.roc', '("content-language", h.?content_language),', '("content-language", Ok(h.?content_language ?? "none")),']),
  R('Object.broadcast!: counts each socket, not each send that works', 'conformance', ['websocket broadcast!: a socket that is closed but still listed is not in the count'], [BP + 'Object.roc', '\t\t\tErr(Closed) => {}\n\t\t}\n\t}\n\t$sent', '\t\t\tErr(Closed) => {\n\t\t\t\t$sent = $sent + 1\n\t\t\t}\n\t\t}\n\t}\n\t$sent']),
  R('Object.broadcast!: sends to one socket only', 'conformance', ['websocket broadcast!: 3 sockets give sent=3 and each gets the message once'], [BP + 'Object.roc', 'send_each!(sockets_of!([]), msg)', 'send_each!(sockets_of!([]).take_first(1), msg)']),
  R('Object.broadcast_with!: the tag is ignored', 'conformance', ['websocket broadcast_with!: only the sockets with the tag get the message'], [BP + 'Object.roc', 'send_each!(sockets_of!([Lit(Text(opts.tag))]), msg)', 'send_each!(sockets_of!([]), msg)']),
  R('Object.broadcast!: sends to the sockets of the tag room only', 'conformance', ['websocket broadcast!: 3 sockets give sent=3 and each gets the message once'], [BP + 'Object.roc', 'broadcast! = |_self, msg| send_each!(sockets_of!([]), msg)', 'broadcast! = |_self, msg| send_each!(sockets_of!([Lit(Text("none"))]), msg)']),
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
  // PLAN.md 8c, D1, Sql and Memo. A wrong JS method name in one function: its route fails.
  R('D1.all: all is called "allx"', 'conformance', ['d1 all!', 'd1 all (Io twin), all_with! and twin'], [BP + 'D1.roc', 'Call(Slot(s), "all", [])', 'Call(Slot(s), "allx", [])']),
  R('D1.first: first is called "firstx"', 'conformance', ['d1 first!: a row, and NotFound for no row'], [BP + 'D1.roc', 'Call(Slot(s), "first", [])', 'Call(Slot(s), "firstx", [])']),
  R('D1.run: run is called "runx"', 'conformance', ['d1 run!, run (Io twin): the info of an insert; last_row_id Ok(5)'], [BP + 'D1.roc', 'Call(Slot(s), "run", [])', 'Call(Slot(s), "runx", [])']),
  R('D1.rows: raw is called "rawx"', 'conformance', ['d1 rows!, rows (Io twin), rows_with!: columns and Sql values'], [BP + 'D1.roc', 'Call(Slot(s), "raw", [', 'Call(Slot(s), "rawx", [']),
  R('D1.batch: batch is called "batchx"', 'conformance', ['d1 batch! of 2 inserts and a select: 3 results, first() of the third reads the count; one crossing', 'd1 batch (Io twin), batch_with! and twin'], [BP + 'D1.roc', 'Call(at.obj, "batch", [Slot(n)])', 'Call(at.obj, "batchx", [Slot(n)])']),
  R('D1.exec: exec is called "execx"', 'conformance', ['d1 exec!, exec (Io twin)'], [BP + 'D1.roc', 'Call(Slot(0), "exec", [', 'Call(Slot(0), "execx", [']),
  R('D1.with_session!: withSession is called "withSessionx"', 'conformance', ['d1 with_session!: bookmark! before and after a query, and After(bookmark)'], [BP + 'D1.roc', '"withSession"', '"withSessionx"']),
  // The tests of PLAN.md 8c.
  R('D1: an Int parameter is sent as a BigInt', 'conformance', ['d1 an Int parameter outside ±(2^53 - 1) stores the exact value'], ['js/helpers.js', '        return v.toString();', '        return v;']),
  R('D1: an Int parameter goes as text only above 2^53', 'conformance', ['d1 an Int parameter outside ±(2^53 - 1) stores the exact value'], ['js/helpers.js', '        return v.toString();', '        return v < 0n ? Number(v) : v.toString();']),
  R('D1: typed rows parse with no int_from_text (Cbor.parse)', 'conformance', ['d1 all! of CAST(id AS TEXT) into { id : I64 } gives the exact ids', 'd1 D1.Result.first of a batch! with no cast: BadData with the column'],
    [BP + 'SqlRules.roc', 'Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True })', 'Cbor.parse(bytes)']),
  R('D1: BadData is Str.inspect of the parse error (no column)', 'conformance', ['d1 all! with no cast: BadData with the column, for a positive and a negative id', 'd1 D1.Result.first of a batch! with no cast: BadData with the column', "d1 the text '01' and '9223372036854775808' into an I64 field give BadData", 'd1 a missing column gives BadData("column id: missing")'],
    [BP + 'SqlRules.roc', 'Err(InvalidCbor(pos)) => Err(BadData(bad_data(bytes, pos)))\n\t\tErr(other) => Err(BadData(missing(Str.inspect(other))))', 'Err(InvalidCbor(pos)) => Err(BadData(Str.inspect(InvalidCbor(pos))))\n\t\tErr(other) => Err(BadData(Str.inspect(other)))']),
  R('D1.all: no Get "results" (API.md 6.2)', 'conformance', ['d1 all!'], [BP + 'D1.roc', 'Get(Slot(s + 1), "results"), Call(Root("pf"), "pack", [Slot(s + 2), Lit(Int(limit(max)))])', 'Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])']),
  R('D1.all: no limit in pf.pack', 'conformance', ['d1 all! of rows above 1 MiB is TooLarge, all_with! with max_bytes of 2 MiB gives the rows'], [BP + 'D1.roc', '"pack", [Slot(s + 2), Lit(Int(limit(max)))]', '"pack", [Slot(s + 2)]']),
  R('D1.Session.bookmark!: getBookmark of null read as text', 'conformance', ['d1 with_session!: bookmark! before and after a query, and After(bookmark)'], [BP + 'D1.roc', 'Ok(Null) => Err(NotFound)', 'Ok(Null) => Ok("")']),
  R('Sql.Info: an I64 field in the meta parse', 'conformance', ['d1 run!: last_row_id of a 64-bit rowid is Err(Rounded)'],
    [BP + 'D1.roc', 'Meta : { changes : U64, last_row_id : F64,', 'Meta : { changes : U64, last_row_id : I64,'], [BP + 'D1.roc', 'last_row_id: row_id(m.last_row_id)', 'last_row_id: row_id(m.last_row_id.to_f64())']),
  R('D1.batch!: a crossing before the batch', 'conformance', ['d1 batch! of 2 inserts and a select: 3 results, first() of the third reads the count; one crossing'],
    [BP + 'D1.roc', 'batch! = |db, stmts| Io.run!(batch(db, stmts))', 'batch! = |db, stmts| {\n\t\t_ = Io.call!([Get(Root("env"), db.name)])\n\t\tIo.run!(batch(db, stmts))\n\t}']),
  // PLAN.md 8d, D1.
  // PLAN.md 8g P1, D1.all_tuples!: one revert for each rule (the method, the limit, the integer rules, the column index).
  R('D1.all_tuples: raw is called "rawx"', 'conformance', ['d1 all_tuples!: rows as tuples, one crossing with a wait; no rows is Ok []', 'd1 all_tuples (Io twin), all_tuples_with! and twin', 'd1 all_tuples! on a D1.Session: all four forms'], [BP + 'D1.roc', 'Call(Slot(s), "raw", []), Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])', 'Call(Slot(s), "rawx", []), Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])']),
  R('D1.all_tuples: no limit in pf.pack', 'conformance', ['d1 all_tuples! of rows above 1 MiB is TooLarge, all_tuples_with! with max_bytes of 2 MiB gives the rows'], [BP + 'D1.roc', 'Call(Slot(s), "raw", []), Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])', 'Call(Slot(s), "raw", []), Call(Root("pf"), "pack", [Slot(s + 1)])']),
  R('D1.all_tuples_with: max_bytes is ignored', 'conformance', ['d1 all_tuples! of rows above 1 MiB is TooLarge, all_tuples_with! with max_bytes of 2 MiB gives the rows'], [BP + 'D1.roc', 'all_tuples_with = |db, sql, params, opts| all_tuples_io(start(db), sql, Cbor.encode(params), opts.max_bytes)', 'all_tuples_with = |db, sql, params, opts| all_tuples_io(start(db), sql, Cbor.encode(params), Body.default_max)']),
  R('D1.Session.all_tuples_with: max_bytes is ignored', 'conformance', ['d1 all_tuples! on a D1.Session: rows above 1 MiB are TooLarge, all_tuples_with! with 2 MiB gives the rows'], [BP + 'D1.roc', 'all_tuples_with = |s, sql, params, opts| all_tuples_io(session_start(s), sql, Cbor.encode(params), opts.max_bytes)', 'all_tuples_with = |s, sql, params, opts| all_tuples_io(session_start(s), sql, Cbor.encode(params), Body.default_max)']),
  R('D1.Session.all_tuples: no limit', 'conformance', ['d1 all_tuples! on a D1.Session: rows above 1 MiB are TooLarge, all_tuples_with! with 2 MiB gives the rows'], [BP + 'D1.roc', 'all_tuples = |s, sql, params| all_tuples_io(session_start(s), sql, Cbor.encode(params), Body.default_max)', 'all_tuples = |s, sql, params| all_tuples_io(session_start(s), sql, Cbor.encode(params), 100_000_000)']),
  R('D1.all_tuples: typed rows parse with no int_from_text (Cbor.parse)', 'conformance', ['d1 all_tuples! of CAST(id AS TEXT) into an I64 item gives the exact ids'], [BP + 'SqlRules.roc', 'typed_tuples = |bytes| match Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True }) {', 'typed_tuples = |bytes| match Cbor.parse(bytes) {']),
  R('D1.all_tuples: BadData is Str.inspect of the parse error (no column)', 'conformance', ['d1 all_tuples! with no cast: BadData with the column index, for a positive and a negative id'], [BP + 'SqlRules.roc', 'Err(InvalidCbor(pos)) => Err(BadData(bad_tuple_data(bytes, pos)))', 'Err(InvalidCbor(pos)) => Err(BadData(Str.inspect(InvalidCbor(pos))))']),
  R('D1.all_tuples: no CAST hint for an integer above 2^53', 'conformance', ['d1 all_tuples! with no cast: BadData with the column index, for a positive and a negative id'], [BP + 'SqlRules.roc', 'Ok([Index(_), Index(c), ..]) =>\n\t\tif rounded_at(bytes, pos) {', 'Ok([Index(_), Index(c), ..]) =>\n\t\tif Bool.False {']),
  R('D1.all_tuples: the column index counts from 1', 'conformance', ['d1 all_tuples! with no cast: BadData with the column index, for a positive and a negative id'], [BP + 'SqlRules.roc', '"column ${c.to_str()} (from 0): integer of 2^53 or more', '"column ${(c + 1).to_str()} (from 0): integer of 2^53 or more']),
  R('D1 (roc test) all_tuples: typed rows parse with no int_from_text (Cbor.parse)', 'roc test', [], ['platform/SqlRules.roc', 'typed_tuples = |bytes| match Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True }) {', 'typed_tuples = |bytes| match Cbor.parse(bytes) {']),
  R('D1 (roc test) all_tuples: the column index counts from 1', 'roc test', [], ['platform/SqlRules.roc', '"column ${c.to_str()} (from 0): the value does not fit', '"column ${(c + 1).to_str()} (from 0): the value does not fit']),
  R('D1: the old map (constraint failed in the message)', 'conformance', ["d1 8d: a trigger RAISE(ABORT, 'label-conflict') in a batch! gives Trigger, and the batch writes nothing"],
    [BP + 'D1.roc', 'thrown = |t| match SqlRules.constraint_of(t.message) {', 'thrown = |t| match (if t.message.contains("constraint failed") SqlRules.constraint_of(t.message) else Err(NotConstraint)) {']),
  R('D1: the kind from the first words of the text', 'conformance', ['d1 8d: a primary key gives Constraint PrimaryKey'],
    [BP + 'SqlRules.roc', 'Ok({ kind: kind_of(after.drop_suffix(")")), message: before })', 'Ok({ kind: if before.starts_with("UNIQUE") Unique else kind_of(after.drop_suffix(")")), message: before })']),
  R('D1: message keeps the code at the end', 'conformance', ["d1 8d: a trigger RAISE(ABORT, 'label-conflict') in a batch! gives Trigger, and the batch writes nothing"],
    [BP + 'SqlRules.roc', 'Ok({ kind: kind_of(after.drop_suffix(")")), message: before })', 'Ok({ kind: kind_of(after.drop_suffix(")")), message: text })']),
  R('D1: no map (D1Err for each throw)', 'conformance', ['d1 8d: a primary key gives Constraint PrimaryKey', 'd1 8d: a UNIQUE column gives Constraint Unique', 'd1 8d: NOT NULL gives Constraint NotNull', 'd1 8d: CHECK gives Constraint Check', 'd1 8d: a foreign key gives Constraint ForeignKey', 'd1 8d: a STRICT column gives Constraint Datatype', "d1 8d: a trigger RAISE(ABORT, 'UNIQUE constraint failed: x') gives Constraint Trigger"],
    [BP + 'D1.roc', 'thrown = |t| match SqlRules.constraint_of(t.message) {', 'thrown = |t| match SqlRules.constraint_of("") {']),
  R('D1 (roc test): the kind from the first words of the text', 'roc test', [], ['platform/SqlRules.roc', 'Ok({ kind: kind_of(after.drop_suffix(")")), message: before })', 'Ok({ kind: if before.starts_with("UNIQUE") Unique else kind_of(after.drop_suffix(")")), message: before })']),
  // MC11 in the shim: pf.limit (rows!) and the budget of pf.packEach (batch!).
  R('pf.limit: no limit', 'conformance', ['d1 all! of rows above 1 MiB is TooLarge, all_with! with max_bytes of 2 MiB gives the rows'], ['js/values.js', 'w.limit = Math.min(saved, w.n + v.maxBytes);', 'w.limit = saved;']),
  R('pf.packEach: a limit for each item, not for all', 'conformance', ['d1 all! of rows above 1 MiB is TooLarge, all_with! with max_bytes of 2 MiB gives the rows'], ['js/helpers.js', 'new Packed(item?.[key], Infinity, budget)', 'new Packed(item?.[key], maxBytes ?? Infinity)']),
  // Memo.
  R('Memo.get!: pf.pinned is called "pinnedx"', 'conformance', ['memo get!: a second request gets the value with no load!'], [BP + 'Memo.roc', 'Call(Root("pf"), "pinned",', 'Call(Root("pf"), "pinnedx",']),
  R('Memo.get!: the pinned value is not read', 'conformance', ['memo get!: a second request gets the value with no load!'], [BP + 'Memo.roc', 'Ok(Bytes(bytes)) => read(bytes)', 'Ok(Bytes(_)) => Err("not pinned")']),
  R('Memo.get!: the pin has no age', 'conformance', ['memo max_age_ms: a get! after the age loads again'], [BP + 'Memo.roc', 'Lit(Bytes(write(v))), Lit(Int(age))', 'Lit(Bytes(write(v))), Lit(Undefined)']),
  R('Memo.clear!: pf.unpin is called "unpinx"', 'conformance', ['memo clear!: the next get! loads again'], [BP + 'Memo.roc', '"unpin"', '"unpinx"']),
  // The pin table (API.md RS2): Io.pin!, pinned!, unpin! (Js.pin! and its pair in API.md).
  R('Io.pin!: pf.pin is called "pinx"', 'conformance', ['pin pin!, pinned!, unpin!: one call! each, no wait', 'webcrypto a pinned CryptoKey used by a later request'],
    [BP + 'Io.roc', 'Call(Root("pf"), "pin", [Lit(Text(name)), Lit(value), Lit(Int(age))])', 'Call(Root("pf"), "pinx", [Lit(Text(name)), Lit(value), Lit(Int(age))])']),
  R('Io.pinned!: undefined is a value (no NotPinned)', 'conformance', ['pin pin!, pinned!, unpin!: one call! each, no wait', 'pin pinned! of a name with no entry is NotPinned'], [BP + 'Io.roc', 'Ok(Undefined) => Err(NotPinned)', 'Ok(Undefined) => Ok(Undefined)']),
  R('Io.pin!: the age is not sent', 'conformance', ['pin max_age_ms: pinned! after the age is NotPinned'], [BP + 'Io.roc', 'Lit(value), Lit(Int(age))', 'Lit(value), Lit(Undefined)']),
  R('Io.unpin!: pf.unpin is called "unpinx"', 'conformance', ['pin pin!, pinned!, unpin!: one call! each, no wait'], [BP + 'Io.roc', 'Call(Root("pf"), "unpin", [Lit(Text(name))])', 'Call(Root("pf"), "unpinx", [Lit(Text(name))])']),
  R('Io.pin!: a throw is Ok (no PinErr)', 'conformance', ['pin pin! to a full table is PinErr'], [BP + 'Io.roc', 'Err(t) => Err(PinErr(t))', 'Err(_) => Ok({})']),
  // The crossing counter of the shim (PLAN.md 8c, WebCrypto Q2).
  R('shim: js_call is not counted', 'conformance', ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)', 'memo get!: a second request gets the value with no load!'], ['js/bridge.js', '    crossings.call++;\n', '']),
  R('shim: js_await is not counted', 'conformance', ['webcrypto verify! RS256 of a JWT with a JWK (one crossing)', 'd1 batch! of 2 inserts and a select: 3 results, first() of the third reads the count; one crossing'], ['js/bridge.js', '    crossings.await++;\n', '']),
  // Body.Writer.write (the twin, RO1): the route of RC13 writes with it.
  R('Body.Writer.write: no bytes are written', 'conformance', ['r2 put_with! of a stream with length_bytes stores the bytes'], [BP + 'Body.roc', '[Call(Ref(writer), "write", [Lit(Bytes(bytes))])]', '[Call(Ref(writer), "write", [Lit(Bytes([]))])]']),
  // PLAN.md 8f, part 2: Queue, Kv, Email and the Tail Worker.
  R('Queue.send: the binding method is called "sendx" (8f2)', 'conformance', ['queue send!, and each! reads the same type', 'queue send (Io twin), send_with! and twin'], [BP + 'Queue.roc', 'Call(Slot(0), "send", [Lit(write(v))', 'Call(Slot(0), "sendx", [Lit(write(v))']),
  R('Queue.each!: a body that is not an a is acked (8f2)', 'conformance', ['queue each!: a body that is not an a is retried, not acked'], [BP + 'Queue.roc', 'Err(why) => Err("the body is not the type of the queue: ${why}")', 'Err(_why) => Ok({})']),
  R('Queue.Message.ack!: acks the whole batch (8f2)', 'conformance', ['queue Message.ack! of the second message acks only it'], [BP + 'Queue.roc', 'ack! = |m| drop!(of_message(m, "ack", []))', 'ack! = |_m| drop!([Call(Root("event"), "ackAll", [])])']),
  R('pf.findById: the first message (8f2)', 'conformance', ['queue Message.ack! of the second message acks only it', 'queue Message.retry_with! and the batch functions: delaySeconds rounds up'], ['js/helpers.js', 'return array.find((item) => item?.id === id);', 'return array[0];']),
  R('Queue event: attempts is always 1 (8f2)', 'conformance', ['queue each!: msg.attempts is 1, then 2 after an Err'], ['js/events.js', 'attempts: Number(m.attempts),', 'attempts: 1,']),
  R('Queue.Batch.retry_all_with!: no delay (8f2)', 'conformance', ['queue Message.retry_with! and the batch functions: delaySeconds rounds up'], [BP + 'Queue.roc', '[Call(Root("event"), "retryAll", [Lit(Obj(retry_options(delay_ms)))])]', '[Call(Root("event"), "retryAll", [])]']),
  R('Queue.send_batch_with!: no delay (8f2)', 'conformance', ['queue send_batch! and send_batch_with! with delay_ms'], [BP + 'Queue.roc', 'Call(Slot(0), "sendBatch", [Lit(Arr(items)), Lit(Obj(batch_options))])', 'Call(Slot(0), "sendBatch", [Lit(Arr(items))])']),
  R('Queue.send_batch!: an error of Workers is Ok (8f2)', 'conformance', ['queue send_batch! of 101 messages is QueueErr'], [BP + 'Queue.roc', 'Err(t) => Err(QueueErr(t))', 'Err(_t) => Ok({})']),
  R('Queue.v8: the content type is "json" (8f2)', 'conformance', ['queue v8: a Cbor.Bytes field reaches a JS consumer as Uint8Array'], [BP + 'Queue.roc', 'content_type: "v8",', 'content_type: "json",']),
  R('queue entry: an Err of queue! does not throw (8f2)', 'conformance', ['queue queue!: an Err is a throw, so Workers retries the batch'], ['js/index.js', "      log(`queue: ${reason(r.outcome)}`);\n      throw new Error(`queue: ${reason(r.outcome)}`);", "      log(`queue: ${reason(r.outcome)}`);"]),
  R('Kv.get: the binding method is called "getx" (8f2)', 'conformance', ['kv get!, get (Io twin), put!, delete!, and the twins: text', 'kv json: a record with a U64 of 2^60 is exact, and JS reads it as JSON'], [BP + 'Kv.roc', 'Call(Slot(0), "get", [Lit(Text(key))', 'Call(Slot(0), "getx", [Lit(Text(key))']),
  R('Kv.delete: the binding method is called "deletex" (8f2)', 'conformance', ['kv get!, get (Io twin), put!, delete!, and the twins: text'], [BP + 'Kv.roc', 'Call(Slot(0), "delete", [Lit(Text(key))])', 'Call(Slot(0), "deletex", [Lit(Text(key))])']),
  R('pf.readMaybe: no limit (8f2)', 'conformance', ['kv get! of 2 MiB is TooLarge, get_with! with max_bytes gives it', 'kv get! of 2 MiB takes no wasm memory'], ['js/helpers.js', 'return this.readUpTo(stream, max);', 'return this.readUpTo(stream, Infinity);']),
  R('Kv.get_with!: max_bytes is not read (8f2)', 'conformance', ['kv get! of 2 MiB is TooLarge, get_with! with max_bytes gives it'], [BP + 'Kv.roc', 'get_with = |kv, key, opts| get_io(kv, key, opts.?cache_ttl_ms, opts.?max_bytes ?? Body.default_max)', 'get_with = |kv, key, opts| get_io(kv, key, opts.?cache_ttl_ms, Body.default_max)']),
  R('Kv.get_with!: cache_ttl_ms is not sent (8f2)', 'conformance', ['kv get_with! cache_ttl_ms: 30 s is Ok, less is KvErr'], [BP + 'Kv.roc', '[("type", Text("stream")), ("cacheTtl", seconds(ms))]', '[("type", Text("stream"))]']),
  R('Kv.put_with!: the metadata is not sent (8f2)', 'conformance', ['kv put_with! metadata, and get_with_metadata!'], [BP + 'Kv.roc', 'Ok(m) => [("metadata", Packed(m.cbor))]', 'Ok(_m) => []']),
  R('pf.kvMeta: the metadata is dropped (8f2)', 'conformance', ['kv put_with! metadata, and get_with_metadata!'], ['js/helpers.js', "return { value, metadata: res?.metadata === null || res?.metadata === undefined ? undefined : new Packed(res.metadata) };", 'return { value, metadata: undefined };']),
  R('pf.kvList: the metadata is dropped (8f2)', 'conformance', ['kv list!: names, expires_ms and typed metadata'], ['js/helpers.js', "metadata: k.metadata === null || k.metadata === undefined ? undefined : new Packed(k.metadata) }));", 'metadata: undefined }));']),
  R('Kv.put_with!: ttl_ms is not rounded up to whole seconds (8f2)', 'conformance', ['kv put_with! ttl_ms rounds up to whole seconds, and expires_ms'], [BP + 'Kv.roc', 'seconds = |ms| Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest)', 'seconds = |ms| Int((ms // 1000).to_i64_try() ?? I64.highest)']),
  R('Kv.Cell.get!: reads another key (8f2)', 'conformance', ['kv Cell: set!, get!, delete! and the twins'], [BP + 'Kv.roc', 'get = |c| c.kv.get(c.key)', 'get = |c| c.kv.get("other")']),
  R('Email.Mail.forward_with!: the headers are not sent (8f2)', 'conformance', ['email forward_with!: an X-Test header'], [BP + 'Email.roc', 'Call(Root("event"), "forward", [Lit(Text(to)), Slot(0)])', 'Call(Root("event"), "forward", [Lit(Text(to))])']),
  R('Email.Mail.header: the case matters (8f2)', 'conformance', ['email header: the case does not matter, a missing header is Missing'], [BP + 'Email.roc', 'h.name.caseless_ascii_equals(name)', 'h.name == name']),
  R('Email.Mail.set_reject!: setReject is called "setRejectx" (8f2)', 'conformance', ['email set_reject!: the mail is rejected with the reason'], [BP + 'Email.roc', '"setReject"', '"setRejectx"']),
  R('Email.Mail.reply!: reply is called "replyx" (8f2)', 'conformance', ['email reply!: a reply to the sender'], [BP + 'Email.roc', 'Call(Root("event"), "reply", [Slot(0)])', 'Call(Root("event"), "replyx", [Slot(0)])']),
  R('Email.send_raw!: send is called "sendx" (8f2)', 'conformance', ['email send!, send (Io twin) and send_raw!, send_raw (Io twin) give a message id'], [BP + 'Email.roc', 'Call(Slot(0), "send", [Slot(1)])', 'Call(Slot(0), "sendx", [Slot(1)])']),
  R('email entry: an Err of email! does not throw (8f2)', 'conformance', ['email an Err of email! rejects the mail (a throw)'], ['js/index.js', "      log(`email: ${reason(r.outcome)}`);\n      throw new Error(`email: ${reason(r.outcome)}`);", "      log(`email: ${reason(r.outcome)}`);"]),
  R('TraceItem: event is read for each kind, not only for a fetch (8f2)', 'conformance', ['tail the trace of a scheduled run: no event, and the cron log'], ['js/events.js', "const fetched = info && typeof info === 'object' && info.request && typeof info.request === 'object';", 'const fetched = true;']),
  R('Tail: no limit on the batch (8f2)', 'conformance', ['tail a trace with 2 MiB of logs: the handler gets fewer logs, one warning'], ['js/index.js', 'tailEvent(events, tailMaxBytes, log)', 'tailEvent(events, Infinity, log)']),
  R('Tail: a Try field in the tag form (8f2)', 'conformance', ['tail the trace of a fetch that logs and throws'], ['js/events.js', 'event_timestamp_ms: u64(e.eventTimestamp),', 'event_timestamp_ms: { Ok: u64(e.eventTimestamp) },']),
  // QO5 (after the merge of part 1): `queue`, `email` and `tail` only for an app whose manifest has the handler.
  R('QO5: queue, email and tail on each default export (8f2)', 'entry-test', [], [IX, 'if (got && !manifest.handlers.includes(h)) delete', 'if (false) delete']),
  R('QO5: the manifest has no handlers of the default export (8f2)', 'conformance', ['objects the manifest: alarm only on a class with alarm!, the RPC methods on the prototype'],
    [BP + 'Worker.roc', '("default", class_of(w.handlers, ', '("default", class_of([], ']),
  R('QO5 (roc test): the manifest has no handlers of the default export (8f2)', 'roc test', [], ['platform/Worker.roc', '("default", class_of(w.handlers, ', '("default", class_of([], ']),
  // PLAN.md 8f, part 4: other bindings (Ai, Vectorize, Analytics, Version, SecretsStore, Hyperdrive, Assets, Workflows). A wrong JS method
  // name in one function, a field or an option that is not sent, a limit that is not applied, a map that is not made.
  R("Ai.run: run is called \"runx\"", "conformance", ["ai run!: typed input and output, one wait", "ai run (Io twin)", "ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up", "ai run_with!: a gateway with only its id sends only the id", "ai run_with!: max_bytes only sends no options to the binding"], [BP + "Ai.roc", "Call(Slot(0), \"run\", args)", "Call(Slot(0), \"runx\", args)"]),
  R("Ai.stream: run is called \"runx\"", "conformance", ["ai stream!, stream (Io twin): the stream of the model, with stream: true in the input"], [BP + "Ai.roc", "Call(Slot(0), \"run\", [Lit(Text(model)), Slot(2)])", "Call(Slot(0), \"runx\", [Lit(Text(model)), Slot(2)])"]),
  R("Ai.stream: stream is not set in the input", "conformance", ["ai stream!, stream (Io twin): the stream of the model, with stream: true in the input"], [BP + "Ai.roc", "Set(Slot(2), \"stream\",", "Set(Slot(2), \"streamx\","]),
  R("Ai.run: the input is not sent", "conformance", ["ai run!: typed input and output, one wait", "ai run (Io twin)"], [BP + "Ai.roc", "Err(NoGateway) => [Lit(Text(model)), Lit(Packed(Cbor.encode(input)))]", "Err(NoGateway) => [Lit(Text(model)), Lit(Packed([0xa0]))]"]),
  R("Ai.run: the model is not sent", "conformance", ["ai run!: typed input and output, one wait", "ai run (Io twin)"], [BP + "Ai.roc", "Err(NoGateway) => [Lit(Text(model)),", "Err(NoGateway) => [Lit(Text(\"m\")),"]),
  R("Ai.run_with: the gateway option is not sent", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up", "ai run_with!: a gateway with only its id sends only the id"], [BP + "Ai.roc", ", Lit(Obj([(\"gateway\", gateway_js(g))]))]", "]"]),
  R("Ai.Gateway: id is not sent", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up", "ai run_with!: a gateway with only its id sends only the id"], [BP + "Ai.roc", "base = [(\"id\", Text(g.id))]", "base = [(\"idx\", Text(g.id))]"]),
  R("Ai.Gateway: skip_cache is not sent", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up"], [BP + "Ai.roc", "(\"skipCache\", Bool(b))", "(\"skipCachex\", Bool(b))"]),
  R("Ai.Gateway: cache_ttl_ms is not sent", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up"], [BP + "Ai.roc", "(\"cacheTtl\", Int(", "(\"cacheTtlx\", Int("]),
  R("Ai.Gateway: cache_ttl_ms rounds down (MC10)", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up"], [BP + "Ai.roc", "Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest)", "Int((ms // 1000).to_i64_try() ?? I64.highest)"]),
  R("Ai.Gateway: cache_key is not sent", "conformance", ["ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up"], [BP + "Ai.roc", "(\"cacheKey\", Text(k))", "(\"cacheKeyx\", Text(k))"]),
  R("Ai.run: no limit in pf.pack", "conformance", ["ai run!: an output above 1 MiB is TooLarge, run_with! with max_bytes of 2 MiB gives it"], [BP + "Ai.roc", "[Slot(1), Lit(Int(o.max_bytes.to_i64_try() ?? I64.highest))]", "[Slot(1)]"]),
  R("Ai.run_with: max_bytes is ignored", "conformance", ["ai run!: an output above 1 MiB is TooLarge, run_with! with max_bytes of 2 MiB gives it"], [BP + "Ai.roc", "max_bytes: opts.?max_bytes ?? Body.default_max", "max_bytes: Body.default_max"]),
  R("Ai.run: TooLarge is AiErr", "conformance", ["ai run!: an output above 1 MiB is TooLarge, run_with! with max_bytes of 2 MiB gives it"], [BP + "Ai.roc", "if t.name == \"TooLarge\" Err(TooLarge) else Err(AiErr(t))", "Err(AiErr(t))"]),
  R("Ai.run: a parse error is TooLarge, not BadData", "conformance", ["ai run!: an output that does not fit its type is BadData"], [BP + "Ai.roc", "Err(e) => Err(BadData(Str.inspect(e)))", "Err(_) => Err(TooLarge)"]),
  R("Vectorize.query: query is called \"queryx\"", "conformance", ["vectorize query!, query (Io twin): the matches with ids and scores, no values and no metadata by default", "vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back", "vectorize query_with!: an option that the app leaves out is not sent", "vectorize query_with!: return_metadata Indexed and None"], [BP + "Vectorize.roc", "Call(Slot(0), \"query\", [", "Call(Slot(0), \"queryx\", ["]),
  R("Vectorize.upsert: upsert is called \"upsertx\"", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them"], [BP + "Vectorize.roc", "write_io(index, \"upsert\", vectors)", "write_io(index, \"upsertx\", vectors)"]),
  R("Vectorize.insert: insert is called \"insertx\"", "conformance", ["vectorize insert!, insert (Io twin): the same vectors; an id that exists keeps its vector"], [BP + "Vectorize.roc", "write_io(index, \"insert\", vectors)", "write_io(index, \"insertx\", vectors)"]),
  R("Vectorize.get: getByIds is called \"getByIdsx\"", "conformance", ["vectorize get!, get (Io twin): the vectors that exist, with typed metadata"], [BP + "Vectorize.roc", "\"getByIds\"", "\"getByIdsx\""]),
  R("Vectorize.delete: deleteByIds is called \"deleteByIdsx\"", "conformance", ["vectorize delete!, delete (Io twin): the ids go to the binding, the vectors are gone"], [BP + "Vectorize.roc", "\"deleteByIds\"", "\"deleteByIdsx\""]),
  R("Vectorize.query: the vector is not sent", "conformance", ["vectorize query!, query (Io twin): the matches with ids and scores, no values and no metadata by default", "vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "Lit(Arr(values.map(|f| Num(f))))", "Lit(Arr([]))"]),
  R("Vectorize.query_with: the options are not sent", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back", "vectorize query_with!: return_metadata Indexed and None"], [BP + "Vectorize.roc", "Lit(Obj(opts))", "Lit(Obj([]))"]),
  R("Vectorize.QueryOptions: top_k is not sent", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "[(\"topK\", Int(limit(n)))]", "[(\"topKx\", Int(limit(n)))]"]),
  R("Vectorize.QueryOptions: namespace is not sent", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "a.append((\"namespace\", Text(s)))", "a.append((\"namespacex\", Text(s)))"]),
  R("Vectorize.QueryOptions: return_values is not sent", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "(\"returnValues\", Bool(v))", "(\"returnValuesx\", Bool(v))"]),
  R("Vectorize.QueryOptions: return_metadata All is sent as \"indexed\"", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "Ok(All) => c.append((\"returnMetadata\", Text(\"all\")))", "Ok(All) => c.append((\"returnMetadata\", Text(\"indexed\")))"]),
  R("Vectorize.QueryOptions: return_metadata Indexed is sent as \"all\"", "conformance", ["vectorize query_with!: return_metadata Indexed and None"], [BP + "Vectorize.roc", "Ok(Indexed) => c.append((\"returnMetadata\", Text(\"indexed\")))", "Ok(Indexed) => c.append((\"returnMetadata\", Text(\"all\")))"]),
  R("Vectorize.QueryOptions: return_metadata None is not sent", "conformance", ["vectorize query_with!: return_metadata Indexed and None"], [BP + "Vectorize.roc", "Ok(None) => c.append((\"returnMetadata\", Text(\"none\")))", "Ok(None) => c"]),
  R("Vectorize.QueryOptions: filter is not sent", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "Ok(f) => d.append((\"filter\", f))", "Ok(_) => d"]),
  R("Vectorize.Vector: values are not sent", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them", "vectorize insert!, insert (Io twin): the same vectors; an id that exists keeps its vector"], [BP + "Vectorize.roc", "\\\"values\\\":[", "\\\"valuesx\\\":["]),
  R("Vectorize.Vector: id is not sent", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them", "vectorize insert!, insert (Io twin): the same vectors; an id that exists keeps its vector"], [BP + "Vectorize.roc", "\"{\\\"id\\\":${", "\"{\\\"idx\\\":${"]),
  R("Vectorize.Vector: namespace is not sent", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them"], [BP + "Vectorize.roc", ",\\\"namespace\\\":${", ",\\\"namespacex\\\":${"]),
  R("Vectorize.Vector: metadata is not sent", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them"], [BP + "Vectorize.roc", ",\\\"metadata\\\":${write(m)?}", ",\\\"metadatax\\\":${write(m)?}"]),
  R("Vectorize: a mutation gives no mutationId", "conformance", ["vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them", "vectorize delete!, delete (Io twin): the ids go to the binding, the vectors are gone"], [BP + "Vectorize.roc", "field(fs, \"mutationId\")", "field(fs, \"mutationIdx\")"]),
  R("Vectorize: the metadata of a match is not read", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back", "vectorize query_with!: return_metadata Indexed and None", "vectorize get!, get (Io twin): the vectors that exist, with typed metadata"], [BP + "Vectorize.roc", "Ok(m) => Ok(Ok(m))", "Ok(_) => Ok(Err(Missing))"]),
  R("Vectorize: a metadata that does not fit is Missing", "conformance", ["vectorize query_with!: metadata that does not fit the type of the index is BadData with the id"], [BP + "Vectorize.roc", "Err(why) => Err(\"vector ${id}: the metadata does not fit the type: ${why}\")", "Err(_) => Ok(Err(Missing))"]),
  R("Vectorize: the values of a match are not read", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "values = values_of(field(fs, \"values\"))?\n\t\tmetadata = metadata_of(read, id, field(fs, \"metadata\"))?\n\t\tOk({ id, score,", "values = []\n\t\tmetadata = metadata_of(read, id, field(fs, \"metadata\"))?\n\t\tOk({ id, score,"]),
  R("Vectorize: the namespace of a match is not read", "conformance", ["vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back"], [BP + "Vectorize.roc", "Ok({ id, score, values, namespace: opt_text(field(fs, \"namespace\")), metadata })", "Ok({ id, score, values, namespace: Err(Missing), metadata })"]),
  R("Vectorize: the score is not read", "conformance", ["vectorize query!, query (Io twin): the matches with ids and scores, no values and no metadata by default"], [BP + "Vectorize.roc", "number(field(fs, \"score\"))", "number(field(fs, \"scorex\"))"]),
  R("Vectorize.query: no limit in pf.limit", "conformance", ["vectorize query_with!, get!: a result above 1 MiB is TooLarge, query_with! with max_bytes of 2 MB gives it"], [BP + "Vectorize.roc", "Call(Root(\"pf\"), \"limit\", [Slot(1), Lit(Int(limit(max)))])", "Call(Root(\"pf\"), \"limit\", [Slot(1), Lit(Int(limit(100_000_000)))])"]),
  R("Vectorize.query_with: max_bytes is ignored", "conformance", ["vectorize query_with!, get!: a result above 1 MiB is TooLarge, query_with! with max_bytes of 2 MB gives it"], [BP + "Vectorize.roc", "opts.?max_bytes ?? Body.default_max)", "Body.default_max)"]),
  R("Vectorize.get: no limit in pf.limit", "conformance", ["vectorize query_with!, get!: a result above 1 MiB is TooLarge, query_with! with max_bytes of 2 MB gives it"], [BP + "Vectorize.roc", "[Slot(1), Lit(Int(limit(Body.default_max)))]", "[Slot(1), Lit(Int(limit(100_000_000)))]"]),
  R("Vectorize: TooLarge is VectorizeErr", "conformance", ["vectorize query_with!, get!: a result above 1 MiB is TooLarge, query_with! with max_bytes of 2 MB gives it"], [BP + "Vectorize.roc", "if t.name == \"TooLarge\" TooLarge else VectorizeErr(t)", "VectorizeErr(t)"]),
  R("Vectorize.QueryOptions (roc test): max_bytes is sent to Vectorize", "roc test", [], ["platform/Vectorize.roc", "\t\tOk(f) => d.append((\"filter\", f))", "\t\tOk(f) => d.append((\"filter\", f)).append((\"max_bytes\", Int(1)))"]),
  R("Analytics.write: writeDataPoint is called \"writeDataPointx\"", "conformance", ["analytics write!: the local binding, and a binding that is not in the config", "analytics write!: blobs, doubles and indexes reach the binding"], [BP + "Analytics.roc", "\"writeDataPoint\"", "\"writeDataPointx\""]),
  R("Analytics.write: blobs are not sent", "conformance", ["analytics write!: blobs, doubles and indexes reach the binding"], [BP + "Analytics.roc", "(\"blobs\", Arr(", "(\"blobsx\", Arr("]),
  R("Analytics.write: doubles are not sent", "conformance", ["analytics write!: blobs, doubles and indexes reach the binding"], [BP + "Analytics.roc", "(\"doubles\", Arr(", "(\"doublesx\", Arr("]),
  R("Analytics.write: indexes are not sent", "conformance", ["analytics write!: blobs, doubles and indexes reach the binding"], [BP + "Analytics.roc", "(\"indexes\", Arr(", "(\"indexesx\", Arr("]),
  R("Analytics.write!: await! in place of call!", "conformance", ["analytics write!: the local binding, and a binding that is not in the config"], [BP + "Analytics.roc", "write! = |a, point| match Io.call!(", "write! = |a, point| match Io.await!("]),
  R("Version.metadata!: Date.parse is called \"parsex\"", "conformance", ["version metadata!: the local binding", "version metadata!: id, tag and timestamp of a known object"], [BP + "Version.roc", "Call(Slot(4), \"parse\",", "Call(Slot(4), \"parsex\","]),
  R("Version.metadata!: the timestamp is not read", "conformance", ["version metadata!: the local binding", "version metadata!: id, tag and timestamp of a known object"], [BP + "Version.roc", "Get(Slot(0), \"timestamp\")", "Get(Slot(0), \"timestampx\")"]),
  R("Version.metadata!: the tag is not read", "conformance", ["version metadata!: id, tag and timestamp of a known object"], [BP + "Version.roc", "Get(Slot(0), \"tag\")", "Get(Slot(0), \"tagx\")"]),
  R("Version.metadata!: await! in place of call!", "conformance", ["version metadata!: the local binding"], [BP + "Version.roc", "metadata! = |v| match Io.call!(", "metadata! = |v| match Io.await!("]),
  R("SecretsStore.get: get is called \"getx\"", "conformance", ["secretsstore get!: a Secret that shows only by reveal, one wait", "secretsstore get (Io twin)", "secretsstore get!: a secret that does not exist is SecretsStoreErr"], [BP + "SecretsStore.roc", "Call(Slot(0), \"get\", [])", "Call(Slot(0), \"getx\", [])"]),
  R("SecretsStore.get: Io.sync in place of Io.new (status 2)", "conformance", ["secretsstore get!: a Secret that shows only by reveal, one wait", "secretsstore get (Io twin)"], [BP + "SecretsStore.roc", "get = |s| Io.new(", "get = |s| Io.sync("]),
  R("Hyperdrive.config!: connectionString is not read", "conformance", ["hyperdrive config!: the six fields, the two secrets hidden, one call!"], [BP + "Hyperdrive.roc", "[\"connectionString\", \"host\",", "[\"connectionStringx\", \"host\","]),
  R("Hyperdrive.config!: port is not read", "conformance", ["hyperdrive config!: the six fields, the two secrets hidden, one call!"], [BP + "Hyperdrive.roc", "\"host\", \"port\", \"user\",", "\"host\", \"portx\", \"user\","]),
  R("Hyperdrive.config!: password is not read", "conformance", ["hyperdrive config!: the six fields, the two secrets hidden, one call!"], [BP + "Hyperdrive.roc", "\"user\", \"password\", \"database\"]", "\"user\", \"passwordx\", \"database\"]"]),
  R("Hyperdrive.config!: await! in place of call!", "conformance", ["hyperdrive config!: the six fields, the two secrets hidden, one call!"], [BP + "Hyperdrive.roc", "config! = |h| match Io.call!(", "config! = |h| match Io.await!("]),
  R("Hyperdrive.config (roc test): a port above 65535 is U16 wrap", "roc test", [], ["platform/Hyperdrive.roc", "(Text(cs), Text(host), Int(port), Text(user), Text(password), Text(database)) => match port.to_u16_try() {", "(Text(cs), Text(host), Int(port), Text(user), Text(password), Text(database)) => match Ok(port.to_u16_wrap()) {"]),
  R("Assets.fetch: the method is not sent (OO3: Remote.roc)", "conformance", ["assets fetch!: the method of the request (a POST is 405)"], [BP + "Remote.roc", "(\"method\", Lit(Text(req.method.to_str())))", "(\"methodx\", Lit(Text(req.method.to_str())))"]),
  R("Assets.fetch: the headers are not sent (OO3: Remote.roc)", "conformance", ["assets fetch!: the headers of the request (If-None-Match is 304)"], [BP + "Remote.roc", "(\"headers\", Lit(Arr(", "(\"headersx\", Lit(Arr("]),
  R("Assets.fetch: the url is always /hello.txt (OO3: Remote.roc)", "conformance", ["assets fetch!: a file that does not exist is an answer, not an error", "assets fetch!: the url of the request"], [BP + "Remote.roc", "Lit(Text(req.url)), Slot(n)])", "Lit(Text(\"http://assets.local/hello.txt\")), Slot(n)])"]),
  R("Assets.fetch: the body is not read (OO3: Remote.roc)", "conformance", ["assets fetch!: a file, one wait (the body of the answer is read in a second one)", "assets fetch (Io twin)", "assets fetch!: pass the response as it is (a stream), also the Io twin"], [BP + "Remote.roc", "[\"status\", \"headers\", \"body\", \"webSocket\"]", "[\"status\", \"headers\", \"webSocket\"]"]),
  R("Assets.fetch (roc test): a text body is not sent (OO3: Remote.roc)", "roc test", [], ["platform/Remote.roc", "Text(s) => base.append((\"body\", Lit(Text(s))))", "Text(_) => base"]),
  R("Workflows.create: create is called \"createx\"", "conformance", ["workflows create!, create (Io twin): an instance with a new id, and its output has the parameters", "workflows create_with!, create_with (Io twin): the id of the app; the same id is AlreadyExists"], [BP + "Workflows.roc", "Call(Slot(2), \"create\", [Slot(3)])", "Call(Slot(2), \"createx\", [Slot(3)])"]),
  R("Workflows.get: get is called \"getx\"", "conformance", ["workflows get!, get (Io twin): the instance of an id, or NotFound"], [BP + "Workflows.roc", "Call(Slot(0), \"get\", [Lit(Text(id))]), Get(Slot(1), \"id\")", "Call(Slot(0), \"getx\", [Lit(Text(id))]), Get(Slot(1), \"id\")"]),
  R("Workflows.Instance: get is called \"getx\" (each function of an instance)", "conformance", ["workflows status!, status (Io twin): the state, no error, the output as JSON text and typed", "workflows pause!, resume!, send_event!: a waiting instance, then its output has the event", "workflows pause (Io twin), resume (Io twin), send_event (Io twin)", "workflows terminate!, terminate (Io twin): a waiting instance ends; a finished one is WorkflowsErr", "workflows: the stub gets the call that the function names"], [BP + "Workflows.roc", "[Get(Root(\"env\"), i.name), Call(Slot(0), \"get\", [Lit(Text(i.id))])]", "[Get(Root(\"env\"), i.name), Call(Slot(0), \"getx\", [Lit(Text(i.id))])]"]),
  R("Workflows.status: status is called \"statusx\"", "conformance", ["workflows status!, status (Io twin): the state, no error, the output as JSON text and typed"], [BP + "Workflows.roc", "Call(Slot(1), \"status\", [])", "Call(Slot(1), \"statusx\", [])"]),
  R("Workflows.status: JSON.stringify is called \"stringifyx\"", "conformance", ["workflows status!, status (Io twin): the state, no error, the output as JSON text and typed"], [BP + "Workflows.roc", "Call(Slot(6), \"stringify\", [Slot(5)])", "Call(Slot(6), \"stringifyx\", [Slot(5)])"]),
  R("Workflows.pause: pause is called \"pausex\"", "conformance", ["workflows pause!, resume!, send_event!: a waiting instance, then its output has the event", "workflows pause (Io twin), resume (Io twin), send_event (Io twin)"], [BP + "Workflows.roc", "plain(i, \"pause\")", "plain(i, \"pausex\")"]),
  R("Workflows.resume: resume is called \"resumex\"", "conformance", ["workflows pause!, resume!, send_event!: a waiting instance, then its output has the event", "workflows pause (Io twin), resume (Io twin), send_event (Io twin)"], [BP + "Workflows.roc", "plain(i, \"resume\")", "plain(i, \"resumex\")"]),
  R("Workflows.terminate: terminate is called \"terminatex\"", "conformance", ["workflows terminate!, terminate (Io twin): a waiting instance ends; a finished one is WorkflowsErr"], [BP + "Workflows.roc", "plain(i, \"terminate\")", "plain(i, \"terminatex\")"]),
  R("Workflows.send_event: sendEvent is called \"sendEventx\"", "conformance", ["workflows pause!, resume!, send_event!: a waiting instance, then its output has the event", "workflows pause (Io twin), resume (Io twin), send_event (Io twin)", "workflows send_event!: the type and the payload (JSON) reach the binding"], [BP + "Workflows.roc", "Call(Slot(3), \"sendEvent\", [Slot(4)])", "Call(Slot(3), \"sendEventx\", [Slot(4)])"]),
  R("Workflows.create: the parameters are not sent", "conformance", ["workflows create!, create (Io twin): an instance with a new id, and its output has the parameters", "workflows create!: the parameters (JSON) and the id reach the binding; with no id, no id is sent"], [BP + "Workflows.roc", "Err(NoId) => [(\"params\", Slot(1))]", "Err(NoId) => []"]),
  R("Workflows.create: the parameters are not JSON.parse of the text", "conformance", ["workflows create!, create (Io twin): an instance with a new id, and its output has the parameters", "workflows create!: the parameters (JSON) and the id reach the binding; with no id, no id is sent"], [BP + "Workflows.roc", "Call(Slot(0), \"parse\", [Lit(Text(text))]),\n\t\t\t\tGet(Root(\"env\"), w.name),", "Call(Slot(0), \"parsex\", [Lit(Text(text))]),\n\t\t\t\tGet(Root(\"env\"), w.name),"]),
  R("Workflows.create_with: the id is not sent", "conformance", ["workflows create_with!, create_with (Io twin): the id of the app; the same id is AlreadyExists", "workflows create!: the parameters (JSON) and the id reach the binding; with no id, no id is sent"], [BP + "Workflows.roc", "Ok(s) => [(\"id\", Lit(Text(s))), (\"params\", Slot(1))]", "Ok(s) => [(\"idx\", Lit(Text(s))), (\"params\", Slot(1))]"]),
  R("Workflows.send_event: the type is not sent", "conformance", ["workflows send_event!: the type and the payload (JSON) reach the binding"], [BP + "Workflows.roc", "(\"type\", Lit(Text(type)))", "(\"typex\", Lit(Text(type)))"]),
  R("Workflows.send_event: the payload is not sent", "conformance", ["workflows send_event!: the type and the payload (JSON) reach the binding"], [BP + "Workflows.roc", "(\"payload\", Slot(1))", "(\"payloadx\", Slot(1))"]),
  R("Workflows.create: AlreadyExists is WorkflowsErr", "conformance", ["workflows create_with!, create_with (Io twin): the id of the app; the same id is AlreadyExists"], [BP + "Workflows.roc", "contains(\"instance.already_exists\")", "contains(\"instance.already_existsx\")"]),
  R("Workflows.get: NotFound is WorkflowsErr", "conformance", ["workflows get!, get (Io twin): the instance of an id, or NotFound", "workflows: an instance that is gone is NotFound for each function"], [BP + "Workflows.roc", "contains(\"instance.not_found\")", "contains(\"instance.not_foundx\")"]),
  R("Workflows.State: \"paused\" is Queued", "conformance", ["workflows pause!, resume!, send_event!: a waiting instance, then its output has the event"], [BP + "Workflows.roc", "Text(\"paused\") => Paused", "Text(\"paused\") => Queued"]),
  R("Workflows.Status: the output is not read", "conformance", ["workflows status!, status (Io twin): the state, no error, the output as JSON text and typed"], [BP + "Workflows.roc", "output_json = match field(fs, \"output\") {\n\t\t\tText(s) => Ok(s)", "output_json = match field(fs, \"output\") {\n\t\t\tText(_) => Err(NotSet)"]),
  R("Workflows.Status (roc test): the state \"waitingForPause\" is Unknown", "roc test", [], ["platform/Workflows.roc", "Text(\"waitingForPause\") => WaitingForPause", "Text(\"waitingForPause\") => Unknown"]),
  R("Ai.run: a throw is TooLarge", "conformance", ["ai run!: a throw of the binding is AiErr"], [BP + "Ai.roc", "Err(t) => if t.name == \"TooLarge\" Err(TooLarge) else Err(AiErr(t))", "Err(_) => Err(TooLarge)"]),
  R("Ai.stream: a throw is a crash", "conformance", ["ai stream!: a throw is AiErr"], [BP + "Ai.roc", "Ok(other) => crash \"Ai.stream: run gave ${Str.inspect(other)}\"\n\t\t\tErr(t) => Err(AiErr(t))", "Ok(other) => crash \"Ai.stream: run gave ${Str.inspect(other)}\"\n\t\t\tErr(_) => crash \"a throw\""]),
  R("Assets.fetch: a throw is a crash", "conformance", ["assets fetch!: a binding that is not in the config, and a url with no host, are AssetsErr"], [BP + "Assets.roc", "|t| AssetsErr(t))", "|_t| crash \"a throw\")"]),
  R("Vectorize.query: a throw is TooLarge", "conformance", ["vectorize query!: a binding that is not in the config is VectorizeErr"], [BP + "Vectorize.roc", "Ok(js) => matches_of(read, js).map_err(|why| BadData(why))\n\t\t\tErr(t) => Err(read_error(t))", "Ok(js) => matches_of(read, js).map_err(|why| BadData(why))\n\t\t\tErr(_) => Err(TooLarge)"]),
  // PLAN.md 8f, part 1: Objects, RPC, Manifest. The shim (js/index.js, js/events.js, js/tasks.js) and the Roc modules.
  R('8f manifest: no check of a class in Roc with no export', 'conformance', ['objects load: a class in Roc with no export stops the load with its name'],
    [IX, 'if (!classes[kind].has(name)) throw new Error(', 'if (false) throw new Error(']),
  R('8f manifest: no check of an export with no class in Roc', 'conformance', ['objects load: an export with no class in Roc stops the load with its name'],
    [IX, '      if (!entry) throw new Error(', '      if (!entry) return;\n      if (false) throw new Error(']),
  R('8f manifest: the methods are not on the prototype (on the class)', 'conformance', ['objects the manifest: alarm only on a class with alarm!, the RPC methods on the prototype', 'objects rpc: call! and its twin with an Rpc constant on a stub', 'rpc a service binding RPC call to an rpc method of the default export gives the reply'],
    [IX, 'Object.defineProperty(C.prototype, name, { configurable: true', 'Object.defineProperty(C, name, { configurable: true']),
  R('8f manifest: no default RPC methods on the prototype', 'conformance', ['rpc a service binding RPC call to an rpc method of the default export gives the reply', 'rpc one Rpc constant calls an object method and a service method'],
    [IX, '  for (const m of manifest.default) {', '  for (const m of []) {']),
  R('8f: the shim always defines alarm', 'conformance', ['objects a class with no alarm!: set_alarm! gives StorageErr', 'objects the manifest: alarm only on a class with alarm!, the RPC methods on the prototype'],
    [IX, "if (C.handlers.has('alarm')) method(C, 'alarm'", "if (true) method(C, 'alarm'"]),
  R('8f: Init runs with no blockConcurrencyWhile', 'conformance', ['objects init! in blockConcurrencyWhile: two fetch! at the same time to a new object both read its table'],
    [IX, 'ctx.blockConcurrencyWhile(() => C.app.objectInit(name, ctx, env));', 'C.app.objectInit(name, ctx, env).catch(() => {});']),
  R('8f: the shim does not throw on Err of init!', 'conformance', ['objects init! that gives Err: ObjectErr, and the next fetch! runs init! again'],
    [IX, "        done(`${name}.init`, r);", "        if (r.trap) done(`${name}.init`, r);"]),
  R('8f: no Init deadline (js/tasks.js)', 'conformance', ['objects init! past the Init deadline is cancelled: ObjectErr with the name of the task'],
    ['js/tasks.js', "  if (t.kind === 'Init') return t.startedAt + d.initMs;\n", '']),
  R('8f: no timer for the Init deadline (a sweep only at the next request)', 'conformance', ['objects init! past the Init deadline is cancelled: ObjectErr with the name of the task'],
    [IX, '      tick(initMs + 50);\n', '']),
  R('8f: the shim always gives retry_count 0', 'conformance', ['objects alarm!: Err while retry_count < 2 runs 3 times, with retry_count and is_retry'],
    ['js/events.js', 'retry_count: Number(info?.retryCount ?? 0)', 'retry_count: 0']),
  R('8f: no check of a SQLite-backed class in the constructor', 'conformance', ['objects a KV-backed class: its first event names the class and new_sqlite_classes'],
    [IX, 'void ctx.storage.sql.databaseSize;', 'void 0;']),
  R('8f: makeHandler gives a class that does not extend WorkerEntrypoint (RPC to the default export)', 'conformance', ['rpc a service binding RPC call to an rpc method of the default export gives the reply'],
    [IX, 'class Handler extends WorkerEntrypoint {', 'class Handler {']),
  R('8f: the fetch of a named entry point sends Fetch with no name', 'conformance', ['rpc Service.fetch! on a binding with entrypoint Admin reaches the fetch! of Admin'],
    [IX, "'EntrypointFetch', entrypointFetchEvent(name, request), request", "'EntrypointFetch', { kind: 'fetch', request: entrypointFetchEvent(name, request).request }, request"]),
  R('8h: an Err of an RPC callee is a throw (RpcErr), not a reply', 'conformance', ['objects rpc: a callee that gives Err(Nope(3)): the caller gets Err(Remote(Nope(3)))'],
    [BP + 'Rpc.roc', 'Err(e) => Ok(err_head.concat(Cbor.encode(e)))', 'Err(e) => Err(Str.inspect(e))']),
  R('8f: respond! gives InvalidState in an object', 'conformance', ['objects respond! in the Fetch of an object: the response first, the cell after'],
    [IX, 'const early = new Promise((resolve) => (hooks.respond = resolve));\n    const running = run(tag,', "const early = new Promise((resolve) => (hooks.respond = kind === 'ObjectFetch' ? null : resolve));\n    const running = run(tag,"]),
  // PLAN.md 8h wave B (b2-small): set_alarm_in!, typed attachments, the KV ttl clamp, Http.cloudflare_error, the D1 2^53 text.
  R('8h B Kv: ttl_ms is not raised to 60 s', 'conformance', ['kv ttl_ms under 60 s is raised to 60 s (put_with!, the Io twin, Cell.set_with!), and 60 s or more is kept', 'kv put_with! ttl_ms rounds up to whole seconds, and expires_ms'],
    [BP + 'Kv.roc', 'seconds(ms.max(min_ttl_ms))', 'seconds(ms)']),
  R('8h B Kv: ttl_ms is raised to 120 s (a floor too high)', 'conformance', ['kv ttl_ms under 60 s is raised to 60 s (put_with!, the Io twin, Cell.set_with!), and 60 s or more is kept'],
    [BP + 'Kv.roc', 'min_ttl_ms = 60_000', 'min_ttl_ms = 120_000']),
  R('8h B Object.set_alarm_in!: pf.alarmIn does not add Date.now()', 'conformance', ['objects set_alarm_in! and its Io twin: get_alarm! is about now + delay, and the alarm fires after the delay, not at once'],
    ['js/helpers.js', 'return storage.setAlarm(Date.now() + delayMs);', 'return storage.setAlarm(delayMs);']),
  R('8h B Object.set_alarm_at!: the time is moved by 5 s', 'conformance', ['objects set_alarm_at!: get_alarm! gives the time, and the alarm fires at it'],
    [BP + 'Object.roc', '"setAlarm", [Lit(Int(epoch_ms.to_i64_try() ?? I64.highest))])', '"setAlarm", [Lit(Int((epoch_ms + 5000).to_i64_try() ?? I64.highest))])']),
  R('8h B Object.set_alarm_in!: the delay is divided by 1000', 'conformance', ['objects set_alarm_in! and its Io twin: get_alarm! is about now + delay, and the alarm fires after the delay, not at once'],
    [BP + 'Object.roc', 'Call(Root("pf"), "alarmIn", [Slot(0), Lit(Int(delay_ms.to_i64_try() ?? I64.highest))])', 'Call(Root("pf"), "alarmIn", [Slot(0), Lit(Int((delay_ms.to_i64_try() ?? I64.highest) // 1000))])']),
  R('8h B Attachment.get!: no attachment is BadData, not NotFound', 'conformance', ['websocket Attachment: NotFound before set!, a record round trip, and a read as another type is BadData'],
    [BP + 'Object.roc', 'Ok(Null) | Ok(Undefined) => Err(NotFound)\n\t\t\t\tOk(other) => Err(BadData("the attachment', 'Ok(Null) | Ok(Undefined) => Err(BadData("none"))\n\t\t\t\tOk(other) => Err(BadData("the attachment']),
  R('8h B Attachment.set!: no value is written', 'conformance', ['websocket Attachment: NotFound before set!, a record round trip, and a read as another type is BadData'],
    [BP + 'Object.roc', '"serializeAttachment", [Lit(Bytes(write(value)))]', '"serializeAttachment", [Lit(Bytes([]))]']),
  R('8h B Attachment.get!: the BadData text has no slot name', 'conformance', ['websocket Attachment: NotFound before set!, a record round trip, and a read as another type is BadData'],
    [BP + 'Object.roc', 'read(bytes).map_err(|m| BadData("the attachment ${att.name}: ${m}"))', 'read(bytes).map_err(|m| BadData(m))']),
  R('8h B Http.cloudflare_error: a status of 399 is an error', 'conformance', ['http cloudflare_error: a 404 with a normal body, and a status under 400, are NotCloudflareError', 'http cloudflare_error: a text body, the prefix, the digits and the status'],
    [BP + 'Http.roc', 'if res.status < 400 {', 'if res.status < 200 {']),
  // No revert for the 64-byte limit of a Bytes body alone: the limit of the text (the same 64 bytes) after the decode gives the same result.
  R('8h B Http.cloudflare_error: a text of any length', 'conformance', ['http cloudflare_error: a text body, the prefix, the digits and the status'],
    [BP + 'Http.roc', 'Ok(t) => if t.count_utf8_bytes() <= cf_error_max cf_error_code(t)', 'Ok(t) => if Bool.True cf_error_code(t)']),
  R('8h B Http.cloudflare_error: the length limit is 65 bytes', 'conformance', ['http cloudflare_error: a body of 64 bytes is read, a body of 76 bytes is not', 'http cloudflare_error: a text body, the prefix, the digits and the status'],
    [BP + 'Http.roc', 'cf_error_max = 64', 'cf_error_max = 80']),
  R('8h B Http.cloudflare_error: the code is not a number (0 for any digits text)', 'conformance', ['http cloudflare_error: a text body, the prefix, the digits and the status'],
    [BP + 'Http.roc', 'U32.from_str(trimmed.drop_prefix("error code: ")).map_err(|_| NotCloudflareError)', 'Ok(U32.from_str(trimmed.drop_prefix("error code: ")) ?? 0)']),
  R('8h B Http.cloudflare_error: a stream body is read as a text', 'conformance', ['http cloudflare_error: a stream body (open!) is NotCloudflareError'],
    [BP + 'Http.roc', 'Empty | Stream(_) => Err(NotCloudflareError)', 'Empty => Err(NotCloudflareError)\n\t\t\tStream(_) => Ok("error code: 1016")']),
  R('8h B Http.cloudflare_error: a final line end is not allowed', 'conformance', ['http cloudflare_error: a text body, the prefix, the digits and the status'],
    [BP + 'Http.roc', 'trimmed = t.trim()', 'trimmed = t']),
  R('8h B D1: the old text of a float of 2^53 or more', 'conformance', ['d1 all! with no cast: BadData with the column, for a positive and a negative id', 'd1 all_tuples! with no cast: BadData with the column index, for a positive and a negative id', 'objects sql!: the integer rules of D1 (an Int parameter as text, CAST(v AS TEXT) into an I64, BadData with no cast)'],
    [BP + 'SqlRules.roc', 'integer of 2^53 or more, read it with CAST(${c} AS TEXT) into an I64, U64 or Id64 field', 'integer above 2^53, use CAST(${c} AS TEXT)'],
    [BP + 'SqlRules.roc', 'integer of 2^53 or more, read it with CAST(... AS TEXT) into an I64, U64 or Id64 field"\n\t\t} else {', 'integer above 2^53, use CAST(... AS TEXT)"\n\t\t} else {']),
  R('8h B D1: 2^53 exactly is not "2^53 or more" (roc test)', 'roc test', [],
    ['platform/SqlRules.roc', 'f.abs() >= 9_007_199_254_740_992.0', 'f.abs() > 9_007_199_254_740_992.0']),
  R('8f Object.get_alarm: call! in place of await!', 'conformance', ['objects get_alarm! after set_alarm!(t) gives t (and the Io twins)'],
    [BP + 'Object.roc', 'get_alarm = |_self| Io.new(', 'get_alarm = |_self| Io.sync(']),
  R('8f Object.delete_all: no deleteAlarm in the program', 'conformance', ['objects delete_all! with a compatibility date before 2026-02-24'],
    [BP + 'Object.roc', 'Call(Slot(0), "deleteAlarm", []), Call(Slot(0), "deleteAll", [])', 'Call(Slot(0), "deleteAll", [])']),
  R('8f Object.list_with: the prefix is not sent', 'conformance', ['objects cells a1, a2, b1: list_with! with prefix "a" gives ["a1", "a2"]'],
    [BP + 'Object.roc', '\t\t\t\t|> text_opt("prefix", opts.?prefix)\n', '']),
  R('8f Object.sql_run: the module reads changes as for D1', 'conformance', ['objects sql_run! of an insert of 2 rows into a table with no index gives rows_written 2'],
    [BP + 'Object.roc', '(field(fields, "rowsRead"), field(fields, "rowsWritten"))', '(field(fields, "rowsRead"), field(fields, "changes"))']),
  R('8f Object.sql: no pf.pack limit', 'conformance', ['objects sql! of 2 MiB of rows is TooLarge, sql_with! with max_bytes of 4 MiB gives the rows'],
    [BP + 'Object.roc', 'Call(Root("pf"), "pack", [Slot(3), Lit(Int(limit(max)))])', 'Call(Root("pf"), "pack", [Slot(3)])']),
  R('8f Object SQL: no constraint map (SqlErr)', 'conformance', ['objects SQL: a primary key gives Constraint PrimaryKey', 'objects SQL: an insert that breaks a UNIQUE index gives Constraint Unique', 'objects SQL: NOT NULL gives Constraint NotNull', 'objects SQL: CHECK gives Constraint Check', 'objects SQL: a foreign key gives Constraint ForeignKey', 'objects SQL: a STRICT column gives Constraint Datatype', "objects SQL: a trigger RAISE(ABORT, 'label-conflict') gives Constraint Trigger"],
    [BP + 'Object.roc', 'match SqlRules.constraint_of(t.message) {', 'match SqlRules.constraint_of("") {']),
  R('8f Object.id!: an id made in Roc from the name', 'conformance', ['objects id! of a named stub equals self.id in the object'],
    [BP + 'Object.roc', 'Ok(Text(id)) => Ok(id)\n\t\t\t\tOk(other) => crash "Object.id!: idFromName', 'Ok(Text(_)) => Ok(name)\n\t\t\t\tOk(other) => crash "Object.id!: idFromName']),
  R('8f Object: the jurisdiction is not sent', 'conformance', ['objects jurisdiction(Eu): id! gives ObjectErr in Miniflare, a different id on the edge'],
    [BP + 'Object.roc', 'namespace_ops = |obj|\n\tif obj.jurisdiction == "" {', 'namespace_ops = |obj|\n\tif Bool.True {']),
  // A wrong JS method name in one function (as in 8c): its route fails.
  R('8f Object.sql: exec is called "execx"', 'conformance', ['objects sql!: rows of the type of the call', 'objects sql_run! of an insert of 2 rows into a table with no index gives rows_written 2'], ['js/helpers.js', 'return sql.exec(text, ...sqlParams(params));', 'return sql.execx(text, ...sqlParams(params));']),
  R('8f Object.sql_rows: raw is called "rawx"', 'conformance', ['objects sql_rows!, sql_rows_with!: columns and Sql values'], [BP + 'Object.roc', 'Call(Slot(2), "raw", [])', 'Call(Slot(2), "rawx", [])']),
  R('8f Object.set_alarm: setAlarm is called "setAlarmx"', 'conformance', ['objects get_alarm! after set_alarm!(t) gives t (and the Io twins)', 'objects ticker: set_alarm! for the retry check'], [BP + 'Object.roc', '"setAlarm"', '"setAlarmx"']),
  R('8f Object.delete_alarm: deleteAlarm is called "deleteAlarmx"', 'conformance', ['objects get_alarm! after set_alarm!(t) gives t (and the Io twins)'], [BP + 'Object.roc', 'Io.new([Get(Root("ctx"), "storage"), Call(Slot(0), "deleteAlarm", [])]', 'Io.new([Get(Root("ctx"), "storage"), Call(Slot(0), "deleteAlarmx", [])]']),
  R('8f Object.delete_all: deleteAll is called "deleteAllx"', 'conformance', ['objects delete_all!: the table, the cell and the alarm are gone (and the twin)'], [BP + 'Object.roc', 'Call(Slot(0), "deleteAll", [])', 'Call(Slot(0), "deleteAllx", [])']),
  R('8f Object.list: kv.list is called "listx"', 'conformance', ['objects cells a1, a2, b1: list_with! with prefix "a" gives ["a1", "a2"]'], [BP + 'Object.roc', 'Call(Slot(1), "list", [Lit(Obj(o3))])', 'Call(Slot(1), "listx", [Lit(Obj(o3))])']),
  R('8f Object.Cell.get: kv.get is called "getx"', 'conformance', ['objects Object.Cell get!, set!, delete!'], [BP + 'Object.roc', 'kv_ops("get", ', 'kv_ops("getx", ']),
  R('8f Object.Cell.set: kv.put is called "putx"', 'conformance', ['objects Object.Cell get!, set!, delete!'], [BP + 'Object.roc', 'kv_ops("put", ', 'kv_ops("putx", ']),
  R('8f Object.Cell.delete: kv.delete is called "deletex"', 'conformance', ['objects Object.Cell get!, set!, delete!'], [BP + 'Object.roc', 'kv_ops("delete", ', 'kv_ops("deletex", ']),
  R('8f Object.named: getByName is called "getByNamex"', 'conformance', ['objects rpc: call! and its twin with an Rpc constant on a stub', 'objects fetch (Io twin)'], [BP + 'Object.roc', '"getByName"', '"getByNamex"']),
  R('8f Object.from_id: idFromString is called "idFromStringx"', 'conformance', ['objects named_with and from_id_with with location_hint, unique!'], [BP + 'Object.roc', '"idFromString"', '"idFromStringx"']),
  R('8f Object.unique!: newUniqueId is called "newUniqueIdx"', 'conformance', ['objects named_with and from_id_with with location_hint, unique!'], [BP + 'Object.roc', '"newUniqueId"', '"newUniqueIdx"']),
  // OO3: one shared fetch program (Remote.fetch) for Assets, Object and Service: the rename fails the checks of all three.
  R('8f OO3 Remote.fetch (Assets, Object, Service): fetch is called "fetchx"', 'conformance', ["objects fetch (Io twin)", "rpc Service.fetch! on a binding with entrypoint Admin reaches the fetch! of Admin", "assets fetch!: a file, one wait (the body of the answer is read in a second one)", "assets fetch (Io twin)", "assets fetch!: a file that does not exist is an answer, not an error", "assets fetch!: the url of the request", "assets fetch!: pass the response as it is (a stream), also the Io twin"], [BP + 'Remote.roc', 'Call(Slot(target), "fetch",', 'Call(Slot(target), "fetchx",']),
  R('8f Rpc: the reply is not read with pf.pack', 'conformance', ['objects rpc: call! and its twin with an Rpc constant on a stub', 'rpc a service binding RPC call to an rpc method of the default export gives the reply'], [BP + 'Remote.roc', 'Call(Root("pf"), "pack", [Slot(n), Lit(Int(', 'Call(Root("pf"), "packx", [Slot(n), Lit(Int(']),
  R('8f manifest: the manifest instance runs a module that is not stack-first', 'layout-test', [],
    ['js/runner.js', '  if (!x.stack_first()) return undefined;\n', '']),
  // MC5: `Cbor.Bytes` of roc-cbor (the package in the cache of the build) with the derived `encoder_for`.
  R('8f MC5: Cbor.Bytes with the derived encoder_for', 'conformance', ['rpc typed bytes (MC5): a Cbor.Bytes field reaches a JS callee as a Uint8Array, a List(U8) field as an Array'],
    [CBOR, '\t\tencoder_for : encoding -> (Cbor.Bytes, state -> Try(state, err))\n\t\t\twhere [\n\t\t\t\tencoding.encode_bytes : List(U8), state -> Try(state, err),\n\t\t\t]\n\t\tencoder_for = |_| {\n\t\t\tEncoding : encoding\n\n\t\t\t|Cbor.Bytes.(bytes), state| Encoding.encode_bytes(bytes, state)\n\t\t}\n', '\t\tencoder_for : _\n']),
  // PLAN.md 8f part 3: WebSocket, Tcp, Hyperdrive.connect!, FO6, a raw event!.
  R('8f3 Object.Socket: no == on sockets (is_eq is always false)', 'conformance', ['websocket two clients in one room: a message of one reaches the other and not the sender'],
    [BP + 'Object.roc', 'is_eq = |a, b| a.ref == b.ref', 'is_eq = |_a, _b| Bool.False']),
  R('8f3 Object.Socket.attach!: the attachment in JS memory, not serializeAttachment', 'conformance', ['websocket hibernation: the object leaves memory, and the next message reads the attachment of its socket'],
    [BP + 'Object.roc', 'Call(Ref(sock.ref), "serializeAttachment", [Lit(Bytes(write(value)))])', 'Set(Ref(sock.ref), "rocAttachment", Lit(Bytes(write(value))))'],
    [BP + 'Object.roc', 'Call(Ref(sock.ref), "deserializeAttachment", [])', 'Get(Ref(sock.ref), "rocAttachment")']),
  R('8f3 Object.Self.set_auto_response!: the pair is not sent', 'conformance', ['websocket an auto response answers ping with no event'],
    [BP + 'Object.roc', 'Call(Root("ctx"), "setWebSocketAutoResponse", [Slot(0)])', 'Call(Root("ctx"), "setWebSocketAutoResponse", [])']),
  R('8f3 Object.Self.accept_with!: the tags are not sent', 'conformance', ['websocket the Worker gives the upgrade to the object with fetch!, and the client gets the 101 of the object', 'websocket accept_with! of 11 tags is TooLarge'],
    [BP + 'Object.roc', 'Lit(Arr(tags.map(|t| Text(t))))', 'Lit(Arr([]))']),
  R('8f3 Remote.fetch: the webSocket of the response is not read', 'conformance', ['websocket the Worker gives the upgrade to the object with fetch!, and the client gets the 101 of the object'],
    [BP + 'Remote.roc', '["status", "headers", "body", "webSocket"]', '["status", "headers", "body"]']),
  R('8f3 the shim defines no webSocketMessage on an object class', 'conformance', ['websocket the Worker gives the upgrade to the object with fetch!, and the client gets the 101 of the object', 'websocket two clients in one room: a message of one reaches the other and not the sender'],
    [IX, "        socketEvent('webSocketMessage', objectSocketMessage);\n", '']),
  R('8f3 WebSocket.connect: fetch is called "fetchx"', 'conformance', ['websocket connect! to a WebSocket echo server sends and receives one message', 'websocket connect (Io twin), receive (Io twin)'],
    [BP + 'WebSocket.roc', 'Call(Root("global"), "fetch",', 'Call(Root("global"), "fetchx",']),
  R('8f3 pf.wsAccept: no branch for a response with no socket (OP7)', 'conformance', ['websocket connect! to a server that answers 200 gives NotUpgrade (OP7)'],
    ['js/helpers.js', '      if (ws === null || ws === undefined) return undefined;\n      acceptSocket(ws);', '      acceptSocket(ws);']),
  R('8f3 pf.wsReceive: the lost branch takes the message', 'conformance', ['websocket Io.race! of receive and Time.sleep(50), the message at 100 ms: the sleep wins, the next receive! gets it'],
    ['js/helpers.js', '          if (i >= 0) st.waiters.splice(i, 1);\n', ''], ['js/helpers.js', 'resolve(v === st.closed ? v : taken(v));', 'resolve(v);']),
  R('8f3 pf: the default binaryType (a bytes frame is a Blob)', 'conformance', ['websocket a Worker: accept!, respond!, receive! until the close', 'websocket connect_with!: protocols and headers, send_json!, Message.json, a bytes frame'],
    ['js/helpers.js', "    ws.binaryType = 'arraybuffer';", '    void 0;']),
  R('8f3 respond!: a 101 response is complete at once (afterRespondMs runs)', 'conformance', ['websocket a 101 response keeps the task: the socket answers after afterRespondMs, and a wait on a socket has no deadline'],
    ['js/helpers.js', 'tasks.respond(t, Boolean((s && !s.closed) || (ws && !ws.closed)));', 'tasks.respond(t, Boolean(s && !s.closed));']),
  R('8f3 pf.wsReceive: a wait on a socket has the deadline of a wait', 'conformance', ['websocket a 101 response keeps the task: the socket answers after afterRespondMs, and a wait on a socket has no deadline'],
    ['js/helpers.js', '      if (st.closed) return st.closed;\n      c.socketWait = true;\n', '      if (st.closed) return st.closed;\n']),
  // PLAN.md 11c, E47, EP6: the plain steps of a StartTls socket, and the error of start_tls! on a socket of tls Off.
  R('8f3 Tcp.connect_with: StartTls is sent as "on"', 'conformance', ['tcp connect_with! tls StartTls: write! and read! twice before start_tls!'],
    [BP + 'Tcp.roc', 'Ok(StartTls) => "starttls"', 'Ok(StartTls) => "on"']),
  R('8f3 Tcp.connect_with: Off is sent as "starttls"', 'conformance', ['tcp start_tls! on a socket of tls Off is SocketErr (the option secureTransport)'],
    [BP + 'Tcp.roc', 'Ok(Off) | Err(_) => "off"', 'Ok(Off) | Err(_) => "starttls"']),
  // EP11: `start_tls!` releases the locks, and refuses a read in flight and unread bytes.
  R('8f3 EP11 pf.tcpStartTls: the reader and the writer stay locked (opened never settles: the route times out)', 'conformance', ['tcp start_tls! upgrades a socket of tls StartTls: write! and read! over TLS (a local STARTTLS server)'],
    ['js/helpers.js', '      st.reader?.releaseLock();\n      st.writer?.releaseLock();\n', '']),
  R('8f3 EP11 pf.tcpStartTls: no check of unread bytes', 'conformance', ['tcp start_tls! with unread bytes is SocketErr (bytes before the upgrade are never read as TLS), the socket stays plain'],
    ['js/helpers.js', '      if (st.rest) throw new Error(', '      if (false) throw new Error(']),
  R('8f3 EP11 pf.tcpStartTls: no check of a read in flight', 'conformance', ['tcp start_tls! with a read in flight (a read that lost a race) is SocketErr, the socket stays plain'],
    ['js/helpers.js', '      if (st.pending) throw new Error(', '      if (false) throw new Error(']),
  R('8f3 Tcp.write: pf.tcpWrite is called "tcpWritex"', 'conformance', ['tcp connect!, write!, read!, close!', 'tcp connect (Io twin), write (Io twin), read (Io twin), connect_with! tls Off'],
    [BP + 'Tcp.roc', '"tcpWrite"', '"tcpWritex"']),
  R('8f3 pf.tcpRead: the lost branch takes the bytes', 'conformance', ['tcp Io.race! of read and Time.sleep(50), the bytes at 100 ms: the sleep wins, the next read gets them'],
    ['js/helpers.js', 'if (!signal?.aborted && st.pending === read) st.pending = null;', 'if (st.pending === read) st.pending = null;']),
  R('8f3 Tcp.read: the end of the stream is SocketErr', 'conformance', ['tcp read! after the end of the peer is Closed, write! after close! is Closed'],
    [BP + 'Tcp.roc', 'Ok(Undefined) | Ok(Null) => Err(Closed)', 'Ok(Undefined) | Ok(Null) => Err(SocketErr({ name: "End", message: "" }))']),
  R('8f3 pf.tcpWrite: a closed socket is a throw', 'conformance', ['tcp read! after the end of the peer is Closed, write! after close! is Closed'],
    ['js/helpers.js', "      if (st.closed) return 'closed';\n      st.writer ??=", '      st.writer ??='],
    ['js/helpers.js', "        if (st.closed) return 'closed';\n        throw e;", '        throw e;']),
  R('8f3 Hyperdrive.connect: connect is called "connectx"', 'conformance', ['hyperdrive connect!, connect (Io twin): a Tcp socket to the origin of the binding'],
    [BP + 'Hyperdrive.roc', 'Call(Slot(0), "connect", [])', 'Call(Slot(0), "connectx", [])']),
  R('8f3 FO6: a JS call with no argument sends undefined', 'conformance', ['rpc a JS call with no argument of a method whose argument type is {} (FO6)'],
    ['js/events.js', 'const argOf = (arg) => new Packed(arg === undefined ? {} : arg);', 'const argOf = (arg) => new Packed(arg);']),
  // SO3 (PLAN.md 8f, part 3): what a lost branch took in the same turn as the end of the race goes back.
  R('8f3 SO3 pf.tcpRead: bytes that a lost branch took do not go back', 'conformance', ['tcp OP8 in the same turn: a read that loses to a branch with no wait gives its bytes back, the next read gets them'],
    ['js/helpers.js', '        onLoss(signal, () => (st.rest = st.rest ? join(v, st.rest) : v));', '        void join;']),
  R('8f3 SO3 pf.wsReceive: a message that a lost branch took does not go back', 'conformance', ['websocket OP8 in the same turn: a receive that loses to a branch with no wait gives its message back, the next receive gets it'],
    ['js/helpers.js', '        onLoss(signal, () => st.queue.unshift(m));', '        void m;']),
  R('8f3 SO3 race: the give-backs of a lost branch do not run', 'conformance', ['tcp OP8 in the same turn: a read that loses to a branch with no wait gives its bytes back, the next read gets them', 'websocket OP8 in the same turn: a receive that loses to a branch with no wait gives its message back, the next receive gets it'],
    ['js/program.js', '  for (const { back } of lost.sort((a, b) => b.n - a.n)) back();', '  void lost;']),
  R('8f3 SO3 race: the winner of an inner race does not give its takes to the branch around it', 'program-test', [],
    ['js/program.js', '    if (j === i && !ctx.signal?.aborted) losses.get(ctx.signal)?.push(...list);', '    if (j === i) void 0;']),
  R('8f3 SO3 race: the give-backs run first take first', 'program-test', [],
    ['js/program.js', 'lost.sort((a, b) => b.n - a.n)', 'lost.sort((a, b) => a.n - b.n)']),
  R('8f3 a raw event! (manifest Unhandled) loses queue, email and tail', 'entry-test', [],
    [IX, "if (got && !manifest.handlers.includes(h))", "if (got !== undefined && !manifest.handlers.includes(h))"]),
  // PLAN.md 8h: get_or, Io.recover, Io.timeout, and the open error of Json.Encodable (a NaN is BadData).
  R("8h Kv.get_or: NotFound is not the default", "conformance", ["kv get_or!: the default for a key that is not there, the value for one that is"],
    [BP + "Kv.roc", "NotFound => Ok(default)", "NotFound => Err(TooLarge)"]),
  R("8h Kv.get_or: BadData gives the default", "conformance", ["kv get_or!: only NotFound gets the default, a value that does not parse stays BadData"],
    [BP + "Kv.roc", "BadData(m) => Err(BadData(m))\n\t\tTooLarge => Err(TooLarge)", "BadData(_) => Ok(default)\n\t\tTooLarge => Err(TooLarge)"]),
  R("8h Kv.Cell.get_or: the value is dropped", "conformance", ["kv get_or!: the default for a key that is not there, the value for one that is"],
    [BP + "Kv.roc", "get_or = |c, default| c.kv.get_or(c.key, default)", "get_or = |c, default| c.kv.get_or(c.key, default).map(|_| default)"]),
  R("8h Object.Cell.get_or!: the value is dropped", "conformance", ["objects Object.Cell get_or!: the default, then the value"],
    [BP + "Object.roc", "Ok(v) => Ok(v)\n\t\t\tErr(NotFound) => Ok(default)", "Ok(_) => Ok(default)\n\t\t\tErr(NotFound) => Ok(default)"]),
  R("8h Object.Cell.get_or!: BadData gives the default", "conformance", ["objects Object.Cell get_or!: a value of another type is BadData, not the default"],
    [BP + "Object.roc", "Err(BadData(m)) => Err(BadData(m))\n\t\t\tErr(StorageErr(t)) => Err(StorageErr(t))", "Err(BadData(_)) => Ok(default)\n\t\t\tErr(StorageErr(t)) => Err(StorageErr(t))"]),
  R("8h Io.recover: a recovered value is a crash", "conformance", ["io recover: NotFound is a value, a BadData goes to the new error, a value stays (one crossing)"],
    [BP + "Io.roc", "read: |r| read(r).on_err(f) }", "read: |r| match read(r) {\n\t\t\tOk(v) => Ok(v)\n\t\t\tErr(e) => match f(e) {\n\t\t\t\tOk(_) => crash \"recover dropped\"\n\t\t\t\tErr(x) => Err(x)\n\t\t\t}\n\t\t} }"]),
  R("8h Io.timeout: never TimedOut", "conformance", ["time Io.timeout: Ok when the sleep ends in time, TimedOut after the limit, the sleep is aborted", "websocket Io.timeout: receive().timeout(50) is TimedOut, the next one gets the message at 100 ms"],
    [BP + "Io.roc", "Ok(Arr([Int(_), _])) => return Err(TimedOut)", "Ok(Arr([Int(_), b])) => read(branch(b))"]),
  R("8h Io.timeout: always TimedOut", "conformance", ["websocket Io.timeout that does not fire: Ok at once, the sleep is aborted", "io timeout keeps the error of the operation: NotFound is not TimedOut, a value is Ok"],
    [BP + "Io.roc", "Ok(Arr([Int(0), b])) => read(branch(b))", "Ok(Arr([Int(0), _])) => return Err(TimedOut)"]),
  R("8h Kv.put: a NaN is Ok and nothing is stored", "conformance", ["kv json of a record with an F64 field: a value is stored, a NaN is BadData and nothing is sent", "kv F64 field: the twin, put_with! and Cell set! give BadData for a NaN and send nothing, a value is stored"],
    [BP + "Kv.roc", "Err(text) => Io.sync([], |_| Err(BadData(\"the value does not encode: ${text}\")))", "Err(_) => Io.sync([], |_| Ok({}))"]),
  R("8h WebSocket.send_json!: a NaN is Ok", "conformance", ["websocket send_json! of a NaN is BadData and no frame goes out"],
    [BP + "WebSocket.roc", "Err(e) => Err(BadData(Str.inspect(e)))", "Err(_) => Ok({})"]),
  R("8h Object.Socket.send_json!: a NaN is Ok", "conformance", ["websocket two clients in one room: a message of one reaches the other and not the sender"],
    [BP + "Object.roc", "Err(e) => Err(BadData(Str.inspect(e)))", "Err(_) => Ok({})"]),
  R("8h Request.post_json: a NaN is a request with no body", "conformance", ["http Request.post_json: JSON with the content type; a NaN is BadData and nothing is sent"],
    [BP + "Request.roc", "Err(e) => Err(BadData(Str.inspect(e)))", "Err(_) => Ok(Request.get(url))"]),
  R("8h Vectorize: a NaN in the metadata is sent as 0", "conformance", ["vectorize an F64 field in the metadata is sent; a NaN is BadData and no call is made (and the Io twin)"],
    [BP + "Vectorize.roc", "write: |m| Json.to_str_try(m).map_err(|e| Str.inspect(e))", "write: |m| Json.to_str_try(m).on_err(|_| Ok(\"0\"))"]),
  R("8h Workflows.json: a NaN in the params is sent as null", "conformance", ["workflows F64 params and payload: a value is sent as JSON, a NaN is BadData and no call is made"],
    [BP + "Workflows.roc", "write: |v| Json.to_str_try(v).map_err(|e| Str.inspect(e))", "write: |v| Json.to_str_try(v).on_err(|_| Ok(\"null\"))"]),
  R("8h Workflows.send_event!: a NaN is Ok", "conformance", ["workflows F64 params and payload: a value is sent as JSON, a NaN is BadData and no call is made"],
    [BP + "Workflows.roc", "Err(e) => Io.sync([], |_| Err(BadData(\"the payload does not encode: ${Str.inspect(e)}\")))", "Err(_) => Io.sync([], |_| Ok({}))"]),
  R("8h Response.from_json: a NaN gives a 200", "conformance", ["kv json of a record with an F64 field: a value is stored, a NaN is BadData and nothing is sent"],
    [BP + "Response.roc", "Response.from_text(500, \"the response", "Response.from_text(200, \"the response"]),
  R("8h Log: a NaN gives an empty line of fields", "conformance", ["log a NaN field: one line with fields_error, the call does not fail"],
    [BP + "Log.roc", "Err(e) => \"{\\\"fields_error\\\":${Json.to_str(Str.inspect(e))}}\"", "Err(_) => \"{}\""]),
  R("8h Kv.json: Encodable([]) (no F64 field)", "must-not-compile", [],
    [BP + "Kv.roc", "json : Str -> Kv(a) where [a.Json.Encodable(enc),", "json : Str -> Kv(a) where [a.Json.Encodable([]),"]),
  // PLAN.md 8h item 3: SQL parameters as an Encodable tuple or list. JS checks (js/helpers.js `sqlParams`), then the encoders.
  R('SQL params: no I64 range check in sqlParams', 'conformance', ['d1 params: a U64 of 2^63 is BadParam, and no row (never a negative number) is stored', 'objects SQL params: a U64 of 2^63 - 1 is stored exact, 2^63 is BadParam and stores no row'], ['js/helpers.js', '        if (v < I64_MIN || v > I64_MAX) throw new BadParam(`SQL parameter ${i}: the integer ${v} does not fit I64`);\n', '']),
  R('SQL params: a BigInt binds as a Number', 'conformance', ['d1 params: 2^53 + 1 (I64 and U64) and I64 min bind as text and land as the exact integer', 'd1 params: a U64 of 2^63 - 1 is stored exact', 'objects SQL params: 2^53 + 1 binds as text and lands as the exact integer', 'objects SQL params: a U64 of 2^63 - 1 is stored exact, 2^63 is BadParam and stores no row'], ['js/helpers.js', '        return v.toString();', '        return Number(v);']),
  R('SQL params: no map check (a map goes to the binding)', 'conformance', ['d1 params: a tag item is BadParam with the hint for Sql.or_null; a Bool item is BadParam', 'objects SQL params: a record and {} are BadParam; a tag item is BadParam with the hint; a Bool item is BadParam'], ['js/helpers.js', '    if (v === null || v instanceof Uint8Array) return v;\n', '    return v;\n']),
  R('SQL params: a Bool binds', 'conformance', ['d1 params: a tag item is BadParam with the hint for Sql.or_null; a Bool item is BadParam', 'objects SQL params: a record and {} are BadParam; a tag item is BadParam with the hint; a Bool item is BadParam'], ['js/helpers.js', 'case \'string\': case \'number\': return v;', 'case \'string\': case \'number\': case \'boolean\': return v;']),
  R('SQL params: no check that the value is an array', 'conformance', ['d1 params: a record and {} are BadParam (a list or a tuple is needed)', 'objects SQL params: a record and {} are BadParam; a tag item is BadParam with the hint; a Bool item is BadParam'], ['js/helpers.js', '  if (!Array.isArray(params)) {', '  if (false) {']),
  R('SQL params: D1 bind does not check the items (sessions, batch, all forms)', 'conformance', ['d1 params: a U64 of 2^63 is BadParam, and no row (never a negative number) is stored', 'd1 params: a tag item is BadParam with the hint for Sql.or_null; a Bool item is BadParam', 'd1 params: a record and {} are BadParam (a list or a tuple is needed)'], ['js/helpers.js', 'return stmt.bind(...sqlParams(params));', 'return stmt.bind(...params);']),
  R('SQL params: Object sqlExec does not check the items', 'conformance', ['objects SQL params: a U64 of 2^63 - 1 is stored exact, 2^63 is BadParam and stores no row', 'objects SQL params: a record and {} are BadParam; a tag item is BadParam with the hint; a Bool item is BadParam'], ['js/helpers.js', 'return sql.exec(text, ...sqlParams(params));', 'return sql.exec(text, ...params);']),
  R('SQL params: Sql.null encodes as text', 'conformance', ['d1 params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x', 'objects SQL params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x'], [BP + 'Sql.roc', 'where [encoding.encode_null : state -> Try(state, err)]\n\t\tencoder_for = |_| {\n\t\t\tEnc : encoding\n\t\t\t|_, state| Enc.encode_null(state)', 'where [encoding.encode_str : Str, state -> Try(state, err)]\n\t\tencoder_for = |_| {\n\t\t\tEnc : encoding\n\t\t\t|_, state| Enc.encode_str("null", state)']),
  R('SQL params: Sql.or_null(Ok x) encodes as NULL', 'conformance', ['d1 params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x', 'objects SQL params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x'], [BP + 'Sql.roc', 'Some(x) => enc_a(x, state)', 'Some(_) => Enc.encode_null(state)']),
  R('SQL params: Sql.blob is a list of numbers, not bytes', 'conformance', ['d1 params: a tuple of (Str, I64, F64, blob) is stored as text, integer, real, blob (run!, and its Io twin)', 'objects SQL params: a tuple of (Str, I64, F64, blob) is stored as text, integer, real, blob'], [BP + 'Sql.roc', 'blob : List(U8) -> Cbor.Bytes\n\tblob = |list| Cbor.bytes(list)', 'blob : List(U8) -> List(U8)\n\tblob = |list| list']),
  R('SQL params: Sql.Blob of a List(Sql) encodes as text', 'conformance', ['d1 params: a run-time List(Sql) still works, and a session takes a tuple'], [BP + 'Sql.roc', 'Blob(b) => Enc.encode_bytes(b, state)', 'Blob(_) => Enc.encode_str("", state)']),
  R('SQL params: Sql.Real of a List(Sql) encodes as an integer', 'conformance', ['d1 params: a run-time List(Sql) still works, and a session takes a tuple', 'objects SQL params: a run-time List(Sql) still works'], [BP + 'Sql.roc', 'Real(f) => Enc.encode_f64(f, state)', 'Real(_) => Enc.encode_i64(0, state)']),
  // PLAN.md 8h item 2 (checks/rpcerr.mjs): the typed reply `{"Ok": v}` / `{"Err": tag}` and its two sides.
  R('8h: the heads of the reply are swapped in Rpc.on', 'conformance',
    ['rpcerr Ok value: a default entry point, a named entry point and an object', 'rpcerr Err with a payload tag: the caller matches Busy(Str)', 'rpcerr Err with a tag with no payload: the caller matches StillOpen', 'rpcerr the reply on the wire is {"Ok": v} and {"Err": tag} for a JS caller'],
    [BP + 'Rpc.roc', 'Ok(r) => Ok(ok_head.concat(Cbor.encode(r)))', 'Ok(r) => Ok(err_head.concat(Cbor.encode(r)))'],
    [BP + 'Rpc.roc', 'Err(e) => Ok(err_head.concat(Cbor.encode(e)))', 'Err(e) => Ok(ok_head.concat(Cbor.encode(e)))']),
  R('8h: the key of the Ok head is "ok" on the wire', 'conformance',
    ['rpcerr Ok value: a default entry point, a named entry point and an object', 'rpcerr the reply on the wire is {"Ok": v} and {"Err": tag} for a JS caller'],
    [BP + 'Rpc.roc', 'ok_head = [0xa1, 0x62, 0x4f, 0x6b]', 'ok_head = [0xa1, 0x62, 0x6f, 0x6b]']),
  R('8h: the key of the Err head is "err" on the wire', 'conformance',
    ['rpcerr Err with a payload tag: the caller matches Busy(Str)', 'rpcerr Err with a tag with no payload: the caller matches StillOpen', 'rpcerr the reply on the wire is {"Ok": v} and {"Err": tag} for a JS caller'],
    [BP + 'Rpc.roc', 'err_head = [0xa1, 0x63, 0x45, 0x72, 0x72]', 'err_head = [0xa1, 0x63, 0x65, 0x72, 0x72]']),
  R('8h: reply_of maps a Remote reply to BadData', 'conformance',
    ['rpcerr Err with a payload tag: the caller matches Busy(Str)', 'rpcerr Err with a tag with no payload: the caller matches StillOpen', 'rpcerr a JS callee: the plain objects { Ok } and { Err } are Ok, Busy and StillOpen', 'objects rpc: a callee that gives Err(Nope(3)): the caller gets Err(Remote(Nope(3)))'],
    [BP + 'Rpc.roc', 'Ok(e) => Err(Remote(e))', 'Ok(e) => Err(BadData(Str.inspect(e)))']),
  // REVIEW.md N1 (research/rpc-unit-crash): reply_of parses the whole reply with a derived parser of `[Ok(ret), Err(err)]`,
  // as before. With the answer `{}` of `open_lot`, `roc build` of the conformance app crashes (nightly-2026-10-12).
  R('8h N1: reply_of parses the reply with a derived Reply (the answer {} crashes the build)', 'conformance build', [],
    [BP + 'Rpc.roc', "\treply_of = |bytes| {\n\t\tif bytes.starts_with(ok_head) {\n\t\t\tv : Try(ret, _)\n\t\t\tv = Cbor.parse(bytes.drop_first(ok_head.len()))\n\t\t\tmatch v {\n\t\t\t\tOk(r) => Ok(r)\n\t\t\t\tErr(e) => Err(BadData(Str.inspect(e)))\n\t\t\t}\n\t\t} else if bytes.starts_with(err_head) {\n\t\t\tv : Try(err, _)\n\t\t\tv = Cbor.parse(bytes.drop_first(err_head.len()))\n\t\t\tmatch v {\n\t\t\t\tOk(e) => Err(Remote(e))\n\t\t\t\tErr(e) => Err(BadData(Str.inspect(e)))\n\t\t\t}\n\t\t} else {\n\t\t\tErr(BadData(\"not a reply: ${Str.inspect(bytes.take_first(8))}\"))\n\t\t}\n\t}\n", "\treply_of = |bytes| {\n\t\tr : Try(Reply(ret, err), _)\n\t\tr = Cbor.parse(bytes)\n\t\tmatch r {\n\t\t\tOk(Reply.Ok(v)) => Ok(v)\n\t\t\tOk(Reply.Err(e)) => Err(Remote(e))\n\t\t\tErr(e) => Err(BadData(Str.inspect(e)))\n\t\t}\n\t}\n"],
    [BP + 'Rpc.roc', 'ok_head : List(U8)\n', 'Reply(ret, err) := [Ok(ret), Err(err)].{\n\tparser_for : _\n\tencoder_for : _\n}\n\nok_head : List(U8)\n']),
  R('8h: the parser of Rpc.NoErr does not fail (a stray Err reply is not BadData)', 'conformance',
    ['rpcerr a reply { Err } for a method with Rpc.NoErr is BadData'],
    [BP + 'Rpc.roc', 'parser_for = |_| |_state| Err(InvalidCbor(0))', 'parser_for = |_| |state| Ok({ value: crash "NoErr parsed", rest: state })']),
  R('8h: an argument that does not parse has no "bad argument" text', 'conformance',
    ['rpcerr an argument that does not parse is RpcErr with "bad argument"'],
    [BP + 'Rpc.roc', 'Err("bad argument: ${Str.inspect(e)}")', 'Err("bad: ${Str.inspect(e)}")']),
  R('8h: a throw of the callee is BadData, not RpcErr', 'conformance',
    ['rpcerr a Roc callee that crashes: RpcErr', 'rpcerr a JS callee that throws: RpcErr with the message', 'rpcerr an argument that does not parse is RpcErr with "bad argument"', 'rpc an unknown method of a service throws (RpcErr)'],
    [BP + 'Remote.roc', 'Err(t) => Err(RpcErr(t))', 'Err(t) => Err(BadData(t.message))']),
  R('8h: a crash of a Roc callee is a reply, not a throw', 'conformance', ['rpcerr a Roc callee that crashes: RpcErr'],
    [IX, 'if (r.trap) throw new Error(`${tag}: ${r.cancelled ? `cancelled: ${r.cancelled}` : `trap ${r.trap}`}`);\n    if (r.outcome.outcome === \'reply\')', 'if (r.trap) return { Ok: 0 };\n    if (r.outcome.outcome === \'reply\')']),
  // PLAN.md 8h item 1: each handler of Worker.new has its own error type and its own text.
  R('8h: Worker.new drops the Str.inspect of an Err of fetch!', 'conformance', ['rpcerr Worker.new: an Err of fetch! is a log line and a 500 (FetchFail)'],
    [BP + 'Worker.roc', 'Ok(res) => Respond(res)\n\t\t\t\t\t\tErr(e) => Failed(Str.inspect(e))', 'Ok(res) => Respond(res)\n\t\t\t\t\t\tErr(_e) => Failed("error")']),
  R('8h: Worker.new drops the Str.inspect of an Err of scheduled!, queue! and email!', 'conformance',
    ['rpcerr Worker.new: an Err of scheduled! is a log line (UnknownCron)', 'rpcerr Worker.new: an Err of queue! is a log line (Boom)', 'rpcerr Worker.new: an Err of email! is a log line (Boom)'],
    [BP + 'Worker.roc', 'Ok({}) => Done\n\tErr(e) => Failed(Str.inspect(e))', 'Ok({}) => Done\n\tErr(_e) => Failed("error")']),
  R('8h: a tag that is not in err compiles (Rpc.on has a free error type for the handler)', 'must-not-compile', ['rpc_tag_bad.roc'],
    [BP + 'Rpc.roc', 'on : Rpc(arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Handler(self) where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([]), err.Cbor.Encodable([])]', 'on : Rpc(arg, ret, err), (self, arg => Try(ret, err2)) -> Rpc.Handler(self) where [arg.Cbor.Parseable([InvalidCbor(U64), ..errs]), ret.Cbor.Encodable([]), err2.Cbor.Encodable([])]']),
  R('8h: a field of Worker.new of the wrong handler type compiles (fetch! takes a Str)', 'must-not-compile', ['worker_field_bad.roc'],
    [BP + 'Worker.roc', 'fetch! ?: Request => Try(Response, e1),', 'fetch! ?: Str => Try(Response, e1),'],
    [BP + 'Worker.roc', 'Ok(f!) => match f!(req) {', 'Ok(f!) => match f!(Str.inspect(req)) {']),
  // PLAN.md 8h wave B (b1-body): `Response.after`, `Cache.put!` tee, `pf.r2put`, the types of `put!` and `wait_until!`.
  R('after: the work runs before the response (Entry.finish!)', 'conformance', ['after: Response.after in a Worker fetch! answers before the work ends, and the work runs after', 'after: Response.after in a named entry point fetch! answers before the work ends, and the work runs after'],
    [BP + 'Entry.roc', '\t\t\t\tmatch Io.call!([Call(Root("pf"), "respond", [Lit(Entry.outcome(o))])]) {', '\t\t\t\t_ = work!({})\n\t\t\t\tmatch Io.call!([Call(Root("pf"), "respond", [Lit(Entry.outcome(o))])]) {']),
  R('Cache.put: no tee (the response to send has the stream that the put read)', 'conformance', ['cache put! of a stream body gives the response to send: the client body is complete and the cache holds it'],
    [BP + 'Cache.roc', 'Ok(Ref(b)) => Ok({ ..res, body: Stream(b) })', 'Ok(Ref(_)) => Ok(res)']),
  R('Cache.put_after!: no tee (the response to send has the stream that the work reads)', 'conformance', ['cache put_after! of a stream body: the client body is complete and the cache holds it'],
    [BP + 'Cache.roc', '(mine, theirs) = ', '(_mine, theirs) = '],
    [BP + 'Cache.roc', 'Ok({ ..res, body: mine }.after(', 'Ok({ ..res, body: res.body }.after(']),
  R('pf.r2put: no fallback (a stream of no known length is the TypeError of R2)', 'conformance', ['r2 put! of a writer stream of 1 KiB with no length is one put (no multipart upload), content type kept', 'r2 put! of a writer stream of 11 MiB with no length is a multipart upload of 3 parts: size exact, content type kept', 'r2 put! of a writer stream of 5 MiB and 1 byte is two parts (5 MiB, 1 byte)', 'r2 put! of a stream that errors in the middle aborts the upload: no object, no complete', 'r2 put_with! of a Body.writer! stream with no length_bytes stores the bytes'],
    ['js/helpers.js', "    if (!(e instanceof TypeError) || !/known length/.test(String(e.message)) || stream.locked) throw e;\n", '    throw e;\n']),
  R('pf.r2put: no abort on an error', 'conformance', ['r2 put! of a stream that errors in the middle aborts the upload: no object, no complete'],
    ['js/helpers.js', '    await upload.abort().catch(() => {});\n', '']),
  R('pf.r2put: the last part is dropped', 'conformance', ['r2 put! of a writer stream of 11 MiB with no length is a multipart upload of 3 parts: size exact, content type kept', 'r2 put! of a writer stream of 5 MiB and 1 byte is two parts (5 MiB, 1 byte)'],
    ['js/helpers.js', '      parts.push(await upload.uploadPart(parts.length + 1, part.subarray(0, n)));', '      if (!done) parts.push(await upload.uploadPart(parts.length + 1, part.subarray(0, n)));']),
  R('pf.r2put: a part of 6 MiB, not 5 MiB', 'conformance', ['r2 put! of a writer stream of 11 MiB with no length is a multipart upload of 3 parts: size exact, content type kept', 'r2 put! of a writer stream of 5 MiB and 1 byte is two parts (5 MiB, 1 byte)', 'r2 put! of a stream that errors in the middle aborts the upload: no object, no complete'],
    ['js/helpers.js', 'export const R2_PART_BYTES = 5 * 1024 * 1024;', 'export const R2_PART_BYTES = 6 * 1024 * 1024;']),
  R('pf.r2put: only_if goes to a multipart upload (no R2Err)', 'conformance', ['r2 put_with! only_if with a stream of unknown length over 5 MiB is R2Err (no upload, no object)'],
    ['js/helpers.js', '  if (options?.onlyIf || R2_SUM_KEYS.some((k) => options?.[k] !== undefined)) {', '  if (false) {']),
  R('8h wave B: Cache.put! gives {} (a statement that drops the response compiles)', 'must-not-compile', ['after/put put! as a statement'],
    [BP + 'Cache.roc', 'put! : Cache, Str, Response => Try(Response, [CacheErr(Io.Thrown)])\n', 'put! : Cache, Str, Response => Try({}, [CacheErr(Io.Thrown)])\n'],
    [BP + 'Cache.roc', 'put! = |cache, url, res| Io.run!(put(cache, url, res))', 'put! = |cache, url, res| Io.run!(put(cache, url, res)).map_ok(|_| {})']),
  R('8h wave B: Ctx.wait_until! takes any Io (the cache.put twin compiles)', 'must-not-compile', ['after/put wait_until! of cache.put'],
    [BP + 'Ctx.roc', 'wait_until! : Io({}, e) => {}', 'wait_until! : Io(a, e) => {}']),
  // PLAN.md 8h wave B issue 5: bindings and crons of Worker.new.
  R('8h B5: the check of env for the bindings is off (checkEnv, load)', 'conformance',
    ['bindings load: a binding that env does not have: the message names it and the Wrangler part', 'bindings load: DB is a KV namespace (a wrong kind): the message says it is not a D1 database', 'bindings load: KV is a D1 database (the other wrong kind)', 'bindings load: a namespace that env does not have'],
    [IX, 'return problems.length ? new Error(', 'return false ? new Error(']),
  R('8h B5: the check of env for the bindings is off (bindings-test)', 'bindings-test', [],
    [IX, 'return problems.length ? new Error(', 'return false ? new Error(']),
  R('8h B5: a namespace class that is not in objects is not checked', 'bindings-test', [],
    ['js/manifest.js', '!b.script && !Object.hasOwn(out.objects, b.class)', 'false']),
  R('8h B5: a binding name twice is not checked', 'bindings-test', [],
    ['js/manifest.js', 'if (out.bindings.some((x) => x.name === b.name)) throw', 'if (false) throw']),
  R('8h B5: Worker.new does not look for the handler of the cron', 'conformance', ['cron Worker.cron: the run of its expression goes to its handler, not to scheduled!'],
    [BP + 'Worker.roc', 'match crons.find_first(|c| c.cron == s.cron) {', 'match crons.find_first(|c| c.cron != c.cron) {']),
  R('8h B5: a cron of Worker.cron goes before scheduled! (the order is the other way)', 'conformance', ['cron Worker.cron: the run of its expression goes to its handler, not to scheduled!'],
    [BP + 'Worker.roc', 'match crons.find_first(|c| c.cron == s.cron) {', 'match crons.find_first(|c| c.cron == s.cron and h.?scheduled!.is_err()) {']),
  R('8h B5: crons are not in the manifest (Roc)', 'roc test', [], ['platform/Worker.roc', '("crons", texts(w.crons)),', '("crons", Arr([])),']),
  R('8h B5: crons are dropped by checkManifest (sync does not see them)', 'cli-test', [], ['js/manifest.js', '    out.crons.push(c);\n', '']),
  R('8h B5: D1.declare gives the kind kv (roc test)', 'roc test', [], ['platform/D1.roc', 'kind: "d1", props: []', 'kind: "kv", props: []']),
  R('8h B5: D1.declare gives the kind kv (the load)', 'conformance', ['start'], [BP + 'D1.roc', 'kind: "d1", props: []', 'kind: "kv", props: []']),
  R('8h B5: checkConfig ignores the migrations', 'cli-test', [], ['js/cli.mjs', 'for (const mig of cfg.migrations ?? []) {', 'for (const mig of []) {']),
  // roc-cbor 0.2.0 (g-cbor02): Dec as tag 4 in JS, Dec parameters, Queue.json, Cbor.Bytes from a BLOB, BadData of a missing column, optional Options.
  // The names start with `dec0.2:` (a filter: `node conformance/reverts.mjs "dec0.2:"`). `P` edits the package in the cache of the build.
  R('dec0.2: JS decoder reads no tag 4', 'conformance', ['dec encode: Roc bytes of the Dec "frac" decode to { $dec } and encode to the same bytes', 'dec Queue.v8: a JS consumer gets the exact { $dec } objects (the marker survives the structured clone)', 'dec RPC: a Dec crosses a call (JS decode, structured clone, encode) exact'],
    ['js/cbor.js', 'if (t === 4) return this.decimal(level);', '']),
  R('dec0.2: JS encoder writes the marker as a map', 'conformance', ['dec encode: Roc bytes of the Dec "frac" decode to { $dec } and encode to the same bytes', 'dec RPC: a Dec crosses a call (JS decode, structured clone, encode) exact'],
    ['js/values.js', 'if (isDec(v)) return w.dec(v);', '']),
  R('dec0.2: JS encoder writes a negative bignum as tag 2', 'conformance', ['dec encode: Roc bytes of the Dec "bigneg" decode to { $dec } and encode to the same bytes'],
    ['js/cbor.js', 'this.tag(mant >= 0n ? 2 : 3);', 'this.tag(2);']),
  R('dec0.2: SQL parameter: a marker is not a Number', 'conformance', ['dec D1 param: a fractional Dec binds a Number (typeof real)', 'dec D1 param: a Dec with a BigInt mantissa (2^53 or more) and a bignum mantissa bind the nearest Number', 'dec object SQL param: a fractional Dec binds a Number, the list literal [1] binds 1'],
    ['js/helpers.js', '    if (isDec(v)) return decNumber(v);\n', '']),
  R('dec0.2: Queue.json send! gives the marker to JS', 'conformance', ['dec Queue.json send!: a JS consumer gets a Number for each Dec'],
    [BP + 'Queue.roc', 'send_ops = if q.content_type == "json" {\n\t\t\t# JSON has no exact Dec', 'send_ops = if Bool.False {\n\t\t\t# JSON has no exact Dec']),
  R('dec0.2: Queue.json send_batch! gives the marker to JS', 'conformance', ['dec Queue.json send_batch!: each message of the batch has Numbers'],
    [BP + 'Queue.roc', 'send_ops = if q.content_type == "json" {\n\t\t\t[\n\t\t\t\tGet(Root("env"), q.name),\n\t\t\t\tCall(Root("pf"), "plain", [Lit(Arr(items))]),', 'send_ops = if Bool.False {\n\t\t\t[\n\t\t\t\tGet(Root("env"), q.name),\n\t\t\t\tCall(Root("pf"), "plain", [Lit(Arr(items))]),']),
  R('dec0.2: pf.plain gives the value as it is', 'conformance', ['dec Queue.json send!: a JS consumer gets a Number for each Dec', 'dec Queue.json send_batch!: each message of the batch has Numbers'],
    ['js/helpers.js', '      return plain(v);', '      return v;']),
  R('dec0.2: Queue.v8 makes Numbers (goes through pf.plain)', 'conformance', ['dec Queue.v8: a JS consumer gets the exact { $dec } objects (the marker survives the structured clone)'],
    [BP + 'Queue.roc', 'send_ops = if q.content_type == "json" {\n\t\t\t# JSON has no exact Dec', 'send_ops = if Bool.True {\n\t\t\t# JSON has no exact Dec']),
  R('dec0.2: the package reads no tag 4 (a Roc consumer, Memo, Cell, RPC)', 'conformance', ['dec Queue.v8: a Roc consumer reads the exact values back', 'dec Memo: a Dec is exact in the cached read (the second get! has the id of the first, so it did not load again)', 'dec Object.Cell: a Dec is exact (a fraction and the lowest Dec)', 'dec RPC: a Dec crosses a call (JS decode, structured clone, encode) exact'],
    [CBOR, '\t\t\t6 => decimal_fraction(state)\n', '\t\t\t6 => Err(InvalidCbor(state.pos))\n']),
  R('dec0.2: the package writes the whole part of a Dec only', 'conformance', ['dec Queue.v8: a Roc consumer reads the exact values back', 'dec Memo: a Dec is exact in the cached read (the second get! has the id of the first, so it did not load again)', 'dec Object.Cell: a Dec is exact (a fraction and the lowest Dec)'],
    [CBOR, '\t\t\tOk(put_decimal_fraction(out, attos))\n', '\t\t\tOk(put_head(out, 0, whole.to_u64_wrap()))\n']),
  R('dec0.2: the package reads no Dec from a float (a D1 REAL)', 'conformance', ['dec D1 read: a Dec field reads a float, an integer and a float that is not exact in binary'],
    [CBOR, '\t\t\t\tif whole.abs_diff(0) > 170141183460469231731 {', '\t\t\t\tif Bool.True {']),
  R('dec0.2: Cbor.Bytes reads no array (a D1 BLOB)', 'conformance', ['dec D1 BLOB: reads into a Cbor.Bytes field and into List(U8)'],
    [CBOR, '} else if h.major == 4 and h.arg <= state.bytes.len() - h.next {', '} else if Bool.False {']),
  R('dec0.2: a missing column is the inspect text', 'conformance', ['dec D1 a missing column x of a typed row is BadData("column x: missing") (all! and first!)', 'd1 a missing column gives BadData("column id: missing")'],
    [BP + 'SqlRules.roc', '\t\tErr(MissingRequiredField(name)) => Err(BadData("column ${name}: missing"))\n', '']),
  R('dec0.2: typed reads pass no int_from_text (the Options are optional)', 'conformance', ['d1 all! of CAST(id AS TEXT) into { id : I64 } gives the exact ids'],
    [BP + 'SqlRules.roc', 'Cbor.parse_with(bytes, { int_from_text: Bool.True }) {\n\t\tOk(v) => Ok(v)\n\t\tErr(InvalidCbor(pos)) => Err(BadData(bad_data(', 'Cbor.parse_with(bytes, {}) {\n\t\tOk(v) => Ok(v)\n\t\tErr(InvalidCbor(pos)) => Err(BadData(bad_data(']),
  R('dec0.2: parse_with ignores int_from_text', 'conformance', ['dec Cbor.parse_with: {} is parse, { int_from_text: True } reads the text'],
    [CBOR, 'int_from_text: options.?int_from_text ?? Bool.False })\n\t\tparsed', 'int_from_text: Bool.False })\n\t\tparsed']),
  R('dec0.2: Readable has the long error row (a wrapper with the old Parseable form compiles)', 'must-not-compile', [],
    [BP + 'Cbor.roc', 'Try({ value : a, rest : CborPkg.State }, [InvalidCbor(U64), MissingRequiredField(Str), ..errs])),', 'Try({ value : a, rest : CborPkg.State }, [InvalidCbor(U64), ..errs])),']),
];

// The filter: texts of names, joined by `|` (a revert runs when its name has one of them).
const filter = process.argv[2]?.split('|');
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

// Before the long run: each edit of each revert that runs must find its text (a stale entry stops the run here, not
// hours later).
const stale = [];
for (const rv of reverts) {
  if (filter && !filter.some((f) => rv.name.includes(f))) continue;
  const texts = new Map();
  for (const [f, from, to] of rv.edits) {
    let s;
    try {
      s = texts.get(f) ?? readFileSync(root + f, 'utf8');
    } catch {
      continue; // A file of the build cache (CBOR) is there only after the clean build.
    }
    if (!s.includes(from)) stale.push(`${rv.name}: no text to replace in ${f}: ${from.slice(0, 60)}`);
    else texts.set(f, s.replace(from, to));
  }
}
if (stale.length) {
  console.log(`stale reverts (update this list):\n${stale.join('\n')}`);
  process.exit(1);
}

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
  if (filter && !filter.some((f) => rv.name.includes(f))) continue;
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
  } catch (e) {
    // A stale edit (a file of the build cache) is a FAIL of this revert, and the run goes on.
    console.log(`${rv.name}: failed: ${e.message}`);
    bad = true;
  } finally {
    for (const [f, text] of saved) writeFileSync(root + f, text);
  }
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
