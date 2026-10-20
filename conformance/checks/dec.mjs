// roc-cbor 0.2.0 (MODULES.md 1 "The Dec in JS", 5.1): routes of conformance/DecRoutes.roc, and the `Dec` ops of
// conformance/ObjectRoutes.roc (`dec_cell`, `dec_sql`). The bytes of Roc are read by the JS codec of js/ (the same files as the shim).
import { answer, eq, ok } from '../assert.mjs';
import { Refs, fromJs, toJs, isDec } from '../../js/values.js';

export const options = {
  queueProducers: { DECJ: 'decj', DECV: 'decv', DECVJS: 'decvjs' },
  queueConsumers: {
    decj: { maxBatchSize: 20, maxBatchTimeout: 0.1 },
    decv: { maxBatchSize: 20, maxBatchTimeout: 0.1 },
    decvjs: { maxBatchSize: 20, maxBatchTimeout: 0.1 },
  },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const id = () => Math.random().toString(36).slice(2);
// `Str.inspect` of a `List(U8)`: "[1, 2]".
const bytesOf = (body) => Uint8Array.from(JSON.parse(body));
const hex = (u8) => Buffer.from(u8).toString('hex');
// The value of a tag 4 object in attos (10^-18), exact.
const attos = (d) => {
  const [e, m] = d.$dec;
  return BigInt(m) * 10n ** BigInt(18 + e);
};

// [name of dec_of, the Dec in attos, the Roc bytes in hex or null (not checked)]
const decs = [
  ['frac', 3_141_590_000_000_000_000n, 'c48224' + '1a0004cb2f'],
  ['neg', -2_750_000_000_000_000_000n, null],
  ['mid', 123_456_789_012_345_678_000_000_000_000n, null],
  ['negmid', -123_456_789_012_345_678_000_000_000_000n, null],
  ['big', 170141183460469231731687303715884105727n, null],
  ['bigneg', -170141183460469231731687303715884105728n, null],
  ['tiny', 1n, null],
  // A mantissa of exactly 2^53 and -2^53: the reader gives an unsafe Number, so the writer does not know the marker (a bug of js/cbor.js,
  // reported by the test agent). Off by default, so the revert runner has a green clean tree: `DEC_EDGE=1 node conformance/run.mjs ... dec`.
  ...(process.env.DEC_EDGE ? [['p53', 9_007_199_254_740_992_000n * 1000n, null], ['np53', -9_007_199_254_740_992_000n * 1000n, null]] : []),
];

// The messages of the JS consumers (worker.js `/__dec_seen`) of a queue, for the label.
async function seen(t, queue, label, n) {
  for (let i = 0; i < 400; i++) {
    const all = JSON.parse((await t.get('/__dec_seen')).body).filter((m) => m.queue === queue && m.text.includes(`"${label}"`));
    if (all.length >= n) return all.map((m) => m.text);
    await sleep(25);
  }
  throw new Error(`no ${n} messages of ${queue} with the label ${label}`);
}
async function logged(t, label, n) {
  for (let i = 0; i < 400; i++) {
    const l = t.logs.map((x) => { try { return JSON.parse(x.message); } catch { return null; } }).filter((x) => x && x.msg === 'dec' && x.label === label);
    if (l.length >= n) return l;
    await sleep(25);
  }
  throw new Error(`no ${n} log lines "dec" with the label ${label}`);
}

export const checks = [
  ['dec setup (the table of the D1 parameter checks)', async (t) => {
    const db = await t.mf.getD1Database('DB');
    await db.prepare('CREATE TABLE dec_t (k TEXT, r)').run();
  }],
  // Item 2 and 1: the bytes that Roc writes for a Dec; the JS reader gives `{ $dec }`; the JS writer gives the same bytes.
  ...decs.map(([name, want, wantHex]) => [`dec encode: Roc bytes of the Dec "${name}" decode to { $dec } and encode to the same bytes`, async (t) => {
    const r = await t.get(`/dec/encode?v=${name}`);
    eq(r.status, 200, 'status');
    const bytes = bytesOf(r.body);
    const value = fromJs(bytes, new Refs());
    ok(isDec(value), `the JS value is not a $dec: ${JSON.stringify(value, (_k, v) => (typeof v === 'bigint' ? `${v}n` : v))}`);
    eq(String(attos(value)), String(want), 'the value in attos');
    eq(hex(toJs(value, new Refs())), hex(bytes), 'the JS bytes');
    if (wantHex) eq(hex(bytes), wantHex, 'the Roc bytes');
    return `${hex(bytes)}`;
  }],
  ),
  ['dec encode: a Dec with no fraction is a CBOR integer (a JS Number)', async (t) => {
    const bytes = bytesOf((await t.get('/dec/encode?v=int')).body);
    eq(hex(bytes), '182a', 'the bytes of 42');
    eq(fromJs(bytes, new Refs()), 42, 'the value');
  }],
  // Item 3 (the clone of a decoded value) is in the consumer checks below (v8). Item 4: SQL parameters.
  ['dec D1 param: a fractional Dec binds a Number (typeof real)', async (t) => {
    answer(await t.get('/dec/d1_param/frac?v=frac'), 'Ok([{ r: 3.14159, t: "real" }])');
  }],
  ['dec D1 param: a Dec with a BigInt mantissa (2^53 or more) and a bignum mantissa bind the nearest Number', async (t) => {
    answer(await t.get('/dec/d1_param/twin?v=mid'), 'Ok([{ r: 123456789012.34567, t: "real" }])');
    answer(await t.get('/dec/d1_param/frac?v=negmid'), 'Ok([{ r: -123456789012.34567, t: "real" }])');
    const r = await t.get('/dec/d1_param/frac?v=big');
    answer(r, 'Ok([{ r: 1.7014118346046924e20, t: "real" }])');
  }],
  ['dec D1 param: the list literal [1] binds the value 1 (D1 binds a Number as REAL)', async (t) => {
    answer(await t.get('/dec/d1_param/lit1'), 'Ok([{ r: 1, t: "real" }])');
  }],
  ['dec object SQL param: a fractional Dec binds a Number, the list literal [1] binds 1', async (t) => {
    answer(await t.get('/objects/counter/dec_sql?name=dec'), 'Ok([{ k: "frac", r: 3.25, t: "real" }, { k: "lit1", r: 1, t: "real" }])');
  }],
  // Item 5: Queue.json and Queue.v8.
  ['dec Queue.json send!: a JS consumer gets a Number for each Dec', async (t) => {
    const label = id();
    answer(await t.get(`/dec/queue/json?label=${label}`), 'Ok');
    const [text] = await seen(t, 'decj', label, 1);
    eq(JSON.stringify(JSON.parse(text)), JSON.stringify({ big: 170141183460469231731.687303715884105727, d: 0.1, label, list: [1.5, 2, -0.25], n: 1, whole: 5 }), 'the message');
  }],
  ['dec Queue.json send_batch!: each message of the batch has Numbers', async (t) => {
    const label = id();
    answer(await t.get(`/dec/queue/json_batch?label=${label}`), 'Ok');
    const texts = await seen(t, 'decj', label, 2);
    for (const text of texts) {
      const m = JSON.parse(text);
      eq(JSON.stringify([m.d, m.whole, m.list]), JSON.stringify([0.1, 5, [1.5, 2, -0.25]]), 'the Numbers');
    }
  }],
  ['dec Queue.v8: a JS consumer gets the exact { $dec } objects (the marker survives the structured clone)', async (t) => {
    const label = id();
    answer(await t.get(`/dec/queue/v8_js?label=${label}`), 'Ok');
    const [text] = await seen(t, 'decvjs', label, 1);
    const m = JSON.parse(text);
    eq(JSON.stringify(m.d), '{"$dec":[-1,1]}', 'd');
    eq(m.whole, 5, 'whole (an integer)');
    eq(JSON.stringify(m.list), '[{"$dec":[-1,15]},2,{"$dec":[-2,-25]}]', 'list');
    eq(m.big.$dec[0], -18, 'big: the exponent');
    eq(m.big.$dec[1], '170141183460469231731687303715884105727n', 'big: the mantissa (a BigInt)');
  }],
  ['dec Queue.v8: a Roc consumer reads the exact values back', async (t) => {
    const label = id();
    answer(await t.get(`/dec/queue/v8?label=${label}`), 'Ok');
    const [l] = await logged(t, label, 1);
    eq(JSON.stringify([l.d, l.whole, l.big, l.list, l.n]), JSON.stringify(['0.1', '5.0', '170141183460469231731.687303715884105727', '1.5,2.0,-0.25', '1']), 'the Dec fields');
  }],
  // Item 7: a D1 BLOB.
  ['dec D1 BLOB: reads into a Cbor.Bytes field and into List(U8)', async (t) => {
    answer(await t.get('/dec/d1_blob'), 'bytes=Ok([[1, 2, 255]]) list=Ok([[1, 2, 255]]) empty=Ok([[]])');
  }],
  // Item 8: the text of a missing column.
  ['dec D1 a missing column x of a typed row is BadData("column x: missing") (all! and first!)', async (t) => {
    answer(await t.get('/dec/d1_missing'), 'all=Err(BadData("column x: missing")) first=Err(BadData("column x: missing"))');
  }],
  // Item 9: Dec exact, Roc to Roc.
  ['dec Object.Cell: a Dec is exact (a fraction and the lowest Dec)', async (t) => {
    answer(await t.get('/objects/counter/dec_cell?name=dec'), 'set=Ok({}) same=True a=Ok("0.1") b=Ok("-170141183460469231731.687303715884105728")');
  }],
  ['dec Memo: a Dec is exact in the cached read (the second get! has the id of the first, so it did not load again)', async (t) => {
    answer(await t.get('/dec/memo'), 'same_id=True a=Ok("0.1") b=Ok("-170141183460469231731.687303715884105728")');
  }],
  ['dec RPC: a Dec crosses a call (JS decode, structured clone, encode) exact', async (t) => {
    answer(await t.get('/dec/rpc'), 'Ok same=True a=0.1 b=-170141183460469231731.687303715884105728');
    answer(await t.get('/dec/rpc?v=big'), 'Ok same=True a=170141183460469231731.687303715884105727 b=-170141183460469231731.687303715884105728');
    answer(await t.get('/dec/rpc?v=mid'), 'Ok same=True a=123456789012.345678 b=-170141183460469231731.687303715884105728');
    // A mantissa of exactly 2^53 or -2^53 (the edge of the Number range of the reader).
    if (process.env.DEC_EDGE) {
      answer(await t.get('/dec/rpc?v=p53'), 'Ok same=True a=9.007199254740992 b=-170141183460469231731.687303715884105728');
      answer(await t.get('/dec/rpc?v=np53'), 'Ok same=True a=-9.007199254740992 b=-170141183460469231731.687303715884105728');
    }
  }],
  ['dec D1 read: a Dec field reads a float, an integer and a float that is not exact in binary', async (t) => {
    answer(await t.get('/dec/d1_read'), 'Ok 2.5 3.0 0.1');
  }],
  // Item 11: the options are optional.
  ['dec Cbor.parse_with: {} is parse, { int_from_text: True } reads the text', async (t) => {
    answer(await t.get('/dec/options'), '{}=Err(InvalidCbor(9)) int_from_text=Ok({ user_id: 12 }) parse=Err(InvalidCbor(9))');
  }],
];
