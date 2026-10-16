// `WebCrypto` (MODULES.md 10, PLAN.md 8c): routes of conformance/WebCryptoRoutes.roc. Node `crypto` makes the keys and
// checks the signatures of the registry cases (RN6, RN9, RN18). `r.waits` is the number of waits of the task.
import { generateKeyPairSync, createHmac, createVerify, sign as nodeSign } from 'node:crypto';
import { answer, ok, eq } from '../assert.mjs';

export const options = {};

const q = (s) => encodeURIComponent(s);
const b64u = (b) => Buffer.from(b).toString('base64url');
// One RSA key pair of Node for the registry cases, and a JWT signing input made with it.
const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const publicJwk = { ...publicKey.export({ format: 'jwk' }), alg: 'RS256', use: 'sig', kid: 'test-key' };
const privateJwk = { ...privateKey.export({ format: 'jwk' }), alg: 'RS256' };
const jwtInput = `${b64u(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: 'test-key' }))}.${b64u(JSON.stringify({ iss: 'https://token.actions.githubusercontent.com', sub: 'repo:a/b', aud: 'talon' }))}`;
const jwtSignature = nodeSign('sha256', Buffer.from(jwtInput), privateKey);

export const checks = [
  // PLAN.md 8c: both sides derive the same bytes (ECDH on P-256, P-384, P-521, and X25519).
  ['webcrypto derive_bits! Ecdh(P256), both sides', async (t) => answer(await t.get('/webcrypto/agree/p256'), 'same=True bytes=32 third_differs=True')],
  ['webcrypto derive_bits! Ecdh(P384) and Ecdh(P521)', async (t) => {
    answer(await t.get('/webcrypto/agree/p384'), 'same=True bytes=32 third_differs=True');
    answer(await t.get('/webcrypto/agree/p521'), 'same=True bytes=32 third_differs=True');
  }],
  ['webcrypto derive_bits! X25519, both sides', async (t) => answer(await t.get('/webcrypto/agree/x25519'), 'same=True bytes=32 third_differs=True')],
  ['webcrypto generate_key! Ed25519, sign! and verify!', async (t) => {
    const r = await t.get('/webcrypto/ed25519');
    answer(r, 'sig=64 verify=Ok changed=BadSignature');
    eq(r.waits, 4, 'waits (generate, sign, verify, verify)');
  }],
  ['webcrypto RsaOaep encrypt! and decrypt!', async (t) => answer(await t.get('/webcrypto/rsa_oaep'), 'cipher=256 same=True')],
  ['webcrypto AesGcm, AesCbc, AesCtr encrypt! and decrypt!', async (t) => answer(
    await t.get('/webcrypto/aes'),
    'gcm=True cipher=37 gcm128=True keys=32,16 wrong=True cbc=True ctr=True',
  )],
  ['webcrypto export_key! of import_key! of Raw(b)', async (t) => answer(
    await t.get('/webcrypto/raw_roundtrip'),
    'raw=True jwk=True pkcs8=True spki=True data_same=True data_other=True',
  )],
  ['webcrypto generate_key! of Pbkdf2 is CryptoErr', async (t) => {
    const r = await t.get('/webcrypto/generate_err');
    ok(r.status === 200 && r.body.startsWith('CryptoErr '), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  // Each function through its Io twin: one wait each.
  ['webcrypto Io twins', async (t) => {
    const r = await t.get('/webcrypto/twins');
    answer(r, 'ok=True exported=True calls=12');
    eq(r.waits, 12, 'waits');
  }],
  // PLAN.md 8c: `timing_safe_equal!`, `random!` and `random_uuid!` run in `call!`: no wait. Crossings (the counter of
  // the shim, Q2): one `js_call` for each call (2 `random!(16)`, 2 `timing_safe_equal!`, `random_uuid!`), 2 for
  // `random!(100000)` (two chunks, C5), and none for `short` (lists of two lengths, C4): 7 in all.
  ['webcrypto timing_safe_equal!, random!, random_uuid! (call!, no wait)', async (t) => {
    const r = await t.get('/webcrypto/sync');
    const m = /^equal=True differ=False short=False random=16 big=100000 distinct=True uuid=([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/.exec(r.body);
    ok(r.status === 200 && m, `got ${r.status} ${r.body}`);
    eq(r.waits, 0, 'waits');
    eq(r.awaits, 0, 'crossings with a wait (js_await)');
    eq(r.calls, 7, 'crossings with no wait (js_call)');
    return `${r.waits} waits, ${r.awaits} js_await, ${r.calls} js_call, uuid ${m[1]}`;
  }],
  // RN6: RS256 `verify` of a JWT signature with the public key as a JWK, in one crossing (the counter of the shim): one
  // `js_await`. The control imports the key first (`import_key!`, then `verify!`): two.
  ['webcrypto verify! RS256 of a JWT with a JWK (one crossing)', async (t) => {
    const url = (route, sig, data) => `/webcrypto/${route}?jwk=${q(JSON.stringify(publicJwk))}&sig=${sig.toString('hex')}&data=${q(data)}`;
    const r = await t.get(url('rs256_verify', jwtSignature, jwtInput));
    answer(r, 'Ok');
    eq(r.awaits + r.calls, 1, 'crossings');
    eq(r.waits, 1, 'waits');
    const control = await t.get(url('rs256_verify_two', jwtSignature, jwtInput));
    answer(control, 'Ok');
    eq(control.awaits + control.calls, 2, 'crossings of import_key! then verify!');
    return `verify! with a JWK: ${r.awaits + r.calls} crossing; import_key! then verify!: ${control.awaits + control.calls}`;
  }],
  ['webcrypto verify! with a JWK: a wrong signature, a wrong text', async (t) => {
    const bad = Buffer.from(jwtSignature);
    bad[0] ^= 1;
    const url = (sig, data) => `/webcrypto/rs256_verify?jwk=${q(JSON.stringify(publicJwk))}&sig=${sig.toString('hex')}&data=${q(data)}`;
    answer(await t.get(url(bad, jwtInput)), 'BadSignature');
    answer(await t.get(url(jwtSignature, jwtInput + 'x')), 'BadSignature');
  }],
  // RN9, RN18: RS256 `sign` with a PKCS#8 key: Node verifies the signature.
  ['webcrypto sign! RS256 with a PKCS#8 key', async (t) => {
    const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('hex');
    const r = await t.get(`/webcrypto/rs256_sign?pkcs8=${pkcs8}&data=${q(jwtInput)}`);
    ok(r.status === 200 && /^[0-9a-f]{512}$/.test(r.body), `got ${r.status} ${r.body.slice(0, 80)}`);
    const v = createVerify('RSA-SHA256').update(jwtInput).end();
    ok(v.verify(publicKey, Buffer.from(r.body, 'hex')), 'Node does not verify the signature');
    eq(r.waits, 1, 'waits');
    return `${r.body.length / 2} bytes, Node verifies`;
  }],
  ['webcrypto import_key! of a private and a public JWK', async (t) => {
    const r = await t.get(`/webcrypto/jwk_import?priv=${q(JSON.stringify(privateJwk))}&pub=${q(JSON.stringify(publicJwk))}&data=${q(jwtInput)}`);
    const m = /^verify=Ok sig=([0-9a-f]{512})$/.exec(r.body);
    ok(r.status === 200 && m, `got ${r.status} ${r.body.slice(0, 120)}`);
    ok(createVerify('RSA-SHA256').update(jwtInput).end().verify(publicKey, Buffer.from(m[1], 'hex')), 'Node does not verify the signature');
  }],
  // RN9: HMAC-SHA256 of a body: `sign!` gives the bytes of Node and of `hmac_sha256` (Roc).
  ['webcrypto sign! and verify! HMAC-SHA256, hmac_sha256', async (t) => {
    const key = 'webhook-secret', body = '{"action":"opened","n":1}';
    const want = createHmac('sha256', key).update(body).digest('hex');
    const r = await t.get(`/webcrypto/hmac?key=${q(key)}&data=${q(body)}`);
    answer(r, `sign=${want} roc=${want} same=True verify=Ok changed=BadSignature`);
    eq(r.waits, 3, 'waits (sign, verify, verify)');
  }],
  // A key longer than the block (64 bytes): the key is hashed first.
  ['webcrypto hmac_sha256 with a key of 100 bytes', async (t) => {
    const key = 'k'.repeat(100), body = 'body';
    const want = createHmac('sha256', key).update(body).digest('hex');
    answer(await t.get(`/webcrypto/hmac?key=${q(key)}&data=${q(body)}`), `sign=${want} roc=${want} same=True verify=Ok changed=BadSignature`);
  }],
  // RS2: a CryptoKey that one request pins is used by a later request.
  ['webcrypto a pinned CryptoKey used by a later request', async (t) => {
    answer(await t.get('/webcrypto/pin/k1'), 'pinned');
    const body = 'later';
    const want = createHmac('sha256', 'pin-secret').update(body).digest('hex');
    answer(await t.get(`/webcrypto/use/k1?data=${body}`), `sig=${want} verify=Ok roc=${want}`);
    const none = await t.get(`/webcrypto/use/never?data=${body}`);
    answer(none, 'Odd NotPinned');
  }],
];
