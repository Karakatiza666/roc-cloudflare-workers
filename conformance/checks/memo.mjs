// `Memo` (MODULES.md 9): routes of conformance/MemoRoutes.roc. `load!` makes a new id each time, so the same id in two
// requests shows that the second request ran no `load!`.
import { answer, eq, ok } from '../assert.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The log lines of the shim with this text. The lines of workerd can come after the response: wait up to 1 s for `min`.
const linesWith = async (t, text, min) => {
  let got = [];
  for (let i = 0; i < 20; i++) {
    got = t.logs.filter((l) => String(l.message).includes(text));
    if (got.length >= min) break;
    await sleep(50);
  }
  return got.map((l) => String(l.message).trim());
};

const value = /^Ok kid=k1 big=1152921504606846976 made=([0-9a-f-]{36})$/;

export const checks = [
  // PLAN.md 8c: a second request gets the value with no `load!`; a U64 of 2^60 comes back exact.
  ['memo get!: a second request gets the value with no load!', async (t) => {
    answer(await t.get('/memo/clear'), 'cleared');
    const a = await t.get('/memo/get');
    const ma = value.exec(a.body);
    ok(a.status === 200 && ma, `first: got ${a.status} ${a.body}`);
    const b = await t.get('/memo/get');
    const mb = value.exec(b.body);
    ok(b.status === 200 && mb, `second: got ${b.status} ${b.body}`);
    eq(mb[1], ma[1], 'the id of the second request (a new id: load! ran)');
    // The first request: pinned (miss), random_uuid, pin. The second: pinned only. No wait.
    eq(a.waits + b.waits, 0, 'waits');
    eq(b.calls, 1, 'crossings of the second request');
    return `same id ${mb[1]}, the second request: ${b.calls} call!, 0 waits`;
  }],
  ['memo clear!: the next get! loads again', async (t) => {
    const a = value.exec((await t.get('/memo/get')).body);
    answer(await t.get('/memo/clear'), 'cleared');
    const b = value.exec((await t.get('/memo/get')).body);
    ok(a && b && a[1] !== b[1], 'the same id after clear!');
  }],
  ['memo max_age_ms: a get! after the age loads again', async (t) => answer(await t.get('/memo/short'), 'same=False')],
  // Talon slice 108b P1: the shape of List(Jwk.Key) of roc-jwt (records with Try fields, a tag union with List(U8)
  // payloads) comes back from its CBOR form in wasm, and a Memo of it loads once.
  ['memo round trip: the roc-jwt key shape encodes and parses back in wasm', async (t) => answer(await t.get('/memo/roundtrip'), 'same=True')],
  // The compiler fault of slice 108b P1: I128.to_u8_try in a wasm32 dev build. Values from the request, so no constant folds.
  ['memo round trip: small integer types from the request (U8, I8, U16, I16, a List(U8) payload)', async (t) => answer(await t.get('/memo/small?n=200'), 'same=True')],
  ['memo get!: the roc-jwt key shape loads once', async (t) => {
    const re = /^Ok keys=3 made=([0-9a-f-]{36})$/;
    const a = await t.get('/memo/jwks'), b = await t.get('/memo/jwks');
    const ma = re.exec(a.body), mb = re.exec(b.body);
    ok(ma && mb, `got ${a.body} | ${b.body}`);
    const lines = await linesWith(t, 'Memo "conformance-jwks"', 0);
    eq(mb[1], ma[1], `the id of the second request (a new id: load! ran; log: ${lines.join(' | ') || 'none'})`);
    eq(lines.length, 0, 'log lines of conformance-jwks');
  }],
  // MODULES.md 9: a value that does not parse back. It is not pinned, each get! loads, and one log line names the Memo and the error.
  ['memo get!: a value that does not parse back gives one log line and is not pinned', async (t) => {
    const re = /^Ok made=([0-9a-f-]{36})$/;
    const a = re.exec((await t.get('/memo/unreadable')).body), b = re.exec((await t.get('/memo/unreadable')).body);
    ok(a && b, 'two answers');
    ok(a[1] !== b[1], 'the same id twice: the value was pinned');
    const lines = await linesWith(t, 'Memo "conformance-unreadable"', 1);
    await sleep(100);
    const all = await linesWith(t, 'Memo "conformance-unreadable"', 1);
    eq(all.length, 1, 'log lines for the name (one for each isolate)');
    eq(lines[0], 'Memo "conformance-unreadable": the value of load! does not parse back from its CBOR form (InvalidCbor(49) at note). It is not pinned, so each get! runs load! again. Use a type that round-trips (MODULES.md 9).', 'the log line');
    return lines[0];
  }],
  // MODULES.md 9: a pinned value of an older type (the same name) loads again, with no log line; the new value is pinned.
  ['memo get!: an older type of the same name loads again with no log line', async (t) => {
    const re = /^Ok made=([0-9a-f-]{36})$/;
    answer(await t.get('/memo/deploy/clear'), 'cleared');
    const o = re.exec((await t.get('/memo/deploy/older')).body);
    const n1 = re.exec((await t.get('/memo/deploy/newer')).body);
    const n2 = re.exec((await t.get('/memo/deploy/newer')).body);
    ok(o && n1 && n2, 'three answers');
    ok(n1[1] !== o[1], 'newer gave the value of older');
    eq(n2[1], n1[1], 'the second get! of newer (a new id: the value of newer was not pinned)');
    await sleep(100);
    eq((await linesWith(t, 'Memo "conformance-deploy"', 0)).length, 0, 'log lines of conformance-deploy');
  }],
];
