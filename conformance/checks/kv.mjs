// `Kv` and `Kv.Cell` (MODULES.md 5.2, 9, PLAN.md 8f): routes of conformance/KvRoutes.roc on the local namespace `KV` of Miniflare.
// The first check writes the big value (2 MiB) and some keys with the binding of Miniflare, not with the module.
import { answer, eq, ok } from '../assert.mjs';

export const options = { kvNamespaces: ['KV'] };

const q = encodeURIComponent;
const MiB = 1024 * 1024;
const route = (t, name, k = '', extra = '') => t.get(`/kv/${name}?k=${q(k)}${extra}`);
const rand = () => Math.random().toString(36).slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The keys of `list({ prefix })`. Edge form (`t.edge`, PLAN.md 11c): `list` is eventually consistent (a new key or a new
// expiration can show up to 60 s later), so it reads again until `ready(keys)`, for at most 70 s.
async function listed(t, kv, prefix, ready) {
  let keys = (await kv.list({ prefix })).keys;
  for (let i = 0; t.edge && i < 35 && !ready(keys); i++) {
    await sleep(2000);
    keys = (await kv.list({ prefix })).keys;
  }
  return keys;
}

export const checks = [
  ['kv setup (a big value and keys, with the binding of Miniflare)', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    await kv.put('big', 'x'.repeat(2 * MiB));
    await kv.put('small', 'hello');
    // The text of a JS Worker that wrote 2^60 as an integer (a JS number cannot hold it: the text is written by hand).
    await kv.put('js-json', '{"theme":"dark","n":1,"big":1152921504606846976}');
    for (const k of ['p/a', 'p/b', 'p/c', 'q/z']) await kv.put(k, k, { metadata: k === 'p/b' ? { tag: 'bee', n: 2 } : undefined });
  }],
  ['kv get!, get (Io twin), put!, delete!, and the twins: text', async (t) => {
    const k = `t-${rand()}`;
    answer(await route(t, 'get', k), 'Err NotFound');
    answer(await route(t, 'put', k, '&v=hi'), 'Ok {}');
    eq((await route(t, 'get', k)).waits, 1, 'waits of get!');
    answer(await route(t, 'get', k), 'Ok "hi"');
    answer(await route(t, 'get_io', k), 'Ok "hi"');
    answer(await route(t, 'put_io', k, '&v=two'), 'Ok {}');
    answer(await route(t, 'get', k), 'Ok "two"');
    answer(await route(t, 'delete', k), 'Ok {}');
    answer(await route(t, 'get', k), 'Err NotFound');
    answer(await route(t, 'put', k, '&v=again'), 'Ok {}');
    answer(await route(t, 'delete_io', k), 'Ok {}');
    answer(await route(t, 'get_io', k), 'Err NotFound');
  }],
  // N6: `find!` and `find` (the Io twin), on Kv and on Kv.Cell: `NotFound` is a value of the inner `Try`.
  ['kv find!, find (Io twin): a missing key is Ok(Err(NotFound)), a present key Ok(Ok(v)), a bad stored value Err(BadData)', async (t) => {
    const k = `f-${rand()}`;
    answer(await route(t, 'find', k), 'Ok Err(NotFound)');
    answer(await route(t, 'find_io', k), 'Ok Err(NotFound)');
    answer(await route(t, 'put', k, '&v=hi'), 'Ok {}');
    answer(await route(t, 'find', k), 'Ok Ok("hi")');
    answer(await route(t, 'find_io', k), 'Ok Ok("hi")');
    await (await t.mf.getKVNamespace('KV')).put(`${k}-text`, 'not json');
    const bad = await route(t, 'find_json', `${k}-text`);
    ok(bad.body.startsWith('Err Infra(BadData('), `a text that is not JSON: ${bad.body}`);
    answer(await route(t, 'delete', k), 'Ok {}');
    answer(await route(t, 'find', k), 'Ok Err(NotFound)');
  }],
  ['kv Cell find!, find (Io twin): missing is Ok(Err(NotFound)), a value Ok(Ok(v)), a bad stored value Err(BadData)', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    await route(t, 'cell_delete');
    answer(await route(t, 'cell_find'), 'Ok Err(NotFound)');
    answer(await route(t, 'cell_find_io'), 'Ok Err(NotFound)');
    answer(await route(t, 'cell_set', '', '&v=dark'), 'Ok {}');
    answer(await route(t, 'cell_find'), 'Ok Ok({ big: 1152921504606846976, n: 3, theme: "dark" })');
    answer(await route(t, 'cell_find_io'), 'Ok Ok({ big: 1152921504606846976, n: 3, theme: "dark" })');
    await kv.put('cell-prefs', 'not json');
    const bad = await route(t, 'cell_find');
    ok(bad.body.startsWith('Err Infra(BadData('), `a text that is not JSON: ${bad.body}`);
    await route(t, 'cell_delete');
  }],
  // N7: `Kv.Cell.declare` is the binding of its Kv (the kind kv and the name, no props).
  ['kv Cell declare: the binding of the manifest is the kind kv and the name of the namespace', async (t) =>
    answer(await route(t, 'cell_declare'), '{ kind: "kv", name: "KV", props: [] }')],
  ['kv json: a record with a U64 of 2^60 is exact, and JS reads it as JSON', async (t) => {
    const k = `j-${rand()}`;
    answer(await route(t, 'json_put', k, '&v=dark'), 'Ok {}');
    answer(await route(t, 'json_get', k), 'Ok { big: 1152921504606846976, n: 3, theme: "dark" }');
    const stored = await (await t.mf.getKVNamespace('KV')).get(k);
    eq(stored, '{"big":1152921504606846976,"n":3,"theme":"dark"}', 'the stored text (JSON)');
    answer(await route(t, 'json_get', 'js-json'), 'Ok { big: 1152921504606846976, n: 1, theme: "dark" }');
    const bad = await route(t, 'json_get', 'small');
    ok(bad.body.startsWith('Err Infra(BadData('), `a text that is not JSON: ${bad.body}`);
  }],
  ['kv bytes: put! and get! keep each byte', async (t) => {
    const k = `b-${rand()}`;
    answer(await route(t, 'bytes_put', k), 'Ok {}');
    answer(await route(t, 'bytes_get', k), 'Ok [0, 1, 254, 255]');
    eq(JSON.stringify([...new Uint8Array(await (await t.mf.getKVNamespace('KV')).get(k, 'arrayBuffer'))]), '[0,1,254,255]', 'the stored bytes');
  }],
  // PLAN.md 8f: `get!` of 2 MiB is `TooLarge`; `get_with!` with `max_bytes`.
  ['kv get! of 2 MiB is TooLarge, get_with! with max_bytes gives it', async (t) => {
    answer(await route(t, 'len', 'big'), 'Err Infra(TooLarge)');
    answer(await route(t, 'len_with', 'big', `&max=${4 * MiB}`), `Ok len=${2 * MiB}`);
    answer(await route(t, 'len_with_io', 'big', `&max=${4 * MiB}`), `Ok len=${2 * MiB}`);
    answer(await route(t, 'len_with', 'big', `&max=${2 * MiB - 1}`), 'Err Infra(TooLarge)');
    answer(await route(t, 'len_with', 'big', `&max=${2 * MiB}`), `Ok len=${2 * MiB}`);
  }],
  ['kv get! of 2 MiB takes no wasm memory', async (t) => {
    const before = Number((await t.get('/__mem')).body);
    answer(await route(t, 'len', 'big'), 'Err Infra(TooLarge)');
    const grew = Number((await t.get('/__mem')).body) - before;
    ok(grew < 1_048_576, `wasm memory grew by ${grew} bytes`);
    return `${grew} bytes`;
  }],
  // 2e: a cache_ttl_ms under 30 s is raised to 30 s (MODULES.md 5.2), as ttl_ms of put_with! is raised to 60 s. KV throws
  // for a cacheTtl under 30 s, so Ok shows the clamp. `roc test` (platform/Kv.roc, read_options) checks the value that is sent.
  ['kv get_with! cache_ttl_ms under 30 s is raised to 30 s (get_with!, the Io twin, get_with_metadata_with!)', async (t) => {
    for (const ms of [0, 1, 5000, 29_999, 30_000, 90_000]) {
      answer(await route(t, 'get_cache', 'small', `&ttl=${ms}`), 'Ok "hello"');
    }
    answer(await route(t, 'get_cache_io', 'small', '&ttl=5000'), 'Ok "hello"');
    answer(await route(t, 'get_meta_cache', 'small', '&ttl=5000'), 'Ok { metadata: Err(Missing), value: "hello" }');
  }],
  // PLAN.md 8f: `put_with!` metadata and `get_with_metadata!`.
  ['kv put_with! metadata, and get_with_metadata!', async (t) => {
    const k = `m-${rand()}`;
    answer(await route(t, 'put_meta', k, '&v=val'), 'Ok {}');
    answer(await route(t, 'get_meta', k), 'Ok { metadata: Ok({ n: 9, tag: "val" }), value: "val" }');
    answer(await route(t, 'get_meta_io', k), 'Ok { metadata: Ok({ n: 9, tag: "val" }), value: "val" }');
    answer(await route(t, 'get_meta_with', k, '&max=100'), 'Ok { metadata: Ok({ n: 9, tag: "val" }), value: "val" }');
    answer(await route(t, 'get_meta_with_io', k, '&max=100'), 'Ok { metadata: Ok({ n: 9, tag: "val" }), value: "val" }');
    const stored = await (await t.mf.getKVNamespace('KV')).getWithMetadata(k);
    eq(JSON.stringify(stored.metadata), '{"n":9,"tag":"val"}', 'the metadata that JS reads');
    // A key with no metadata: `Err(Missing)`, not an error of the call. A key that is not there: NotFound.
    answer(await route(t, 'get_meta', 'small'), 'Ok { metadata: Err(Missing), value: "hello" }');
    answer(await route(t, 'get_meta', `none-${rand()}`), 'Err NotFound');
    answer(await route(t, 'get_meta_with', 'big', `&max=${MiB}`), 'Err Infra(TooLarge)');
  }],
  // pf.plain: the metadata is JSON in KV. A BigInt (a U64 of 2^60, a U128 of 2^100) is decimal text, a List(U8) base64
  // text. The typed read takes the decimal text (IntFromText, up to 39 digits) and base64 text (BytesFromBase64).
  ['kv put_with! metadata with a U64 of 2^60, a U128 of 2^100 and a List(U8): decimal text and base64 in JSON; the U64 reads back', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    for (const r of ['put_meta_wide', 'put_meta_wide_io']) {
      const k = `w-${rand()}`;
      answer(await route(t, r, k, '&v=val'), 'Ok {}');
      eq(JSON.stringify((await kv.getWithMetadata(k)).metadata), '{"big":"1152921504606846976","data":"AQL/","wide":"1267650600228229401496703205376"}', `${r}: the metadata that JS reads`);
      answer(await route(t, 'get_meta_big', k), 'Ok { metadata: Ok({ big: 1152921504606846976 }), value: "val" }');
      // roc-cbor 0.5.0: IntFromText reads up to 39 digits, so the U128 of 2^100 reads back.
      answer(await route(t, 'get_meta_wide', k), 'Ok { metadata: Ok({ big: 1152921504606846976, wide: 1267650600228229401496703205376 }), value: "val" }');
    }
  }],
  // The round trip through KV metadata (JSON): a List(U8) and a Cbor.Bytes are base64 text (BytesFromBase64), a U128 above 2^64
  // and an I128 below -2^63 are decimal text (IntFromText). get_with_metadata! and Metadata.parse read them back.
  ['kv metadata round trip: List(U8), Cbor.Bytes, U128 above 2^64 and I128 below -2^63 read back (BytesFromBase64, IntFromText)', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    const k = `rt-${rand()}`;
    answer(await route(t, 'put_meta_rt', k, '&v=val'), 'Ok {}');
    eq(JSON.stringify((await kv.getWithMetadata(k)).metadata), '{"bytes":"AID+","data":"AQL/","low":"-170141183460469231731687303715884105728","wide":"1267650600228229401496703205376"}', 'the metadata that JS reads');
    const want = '{ bytes: [0, 128, 254], data: [1, 2, 255], low: -170141183460469231731687303715884105728, wide: 1267650600228229401496703205376 }';
    answer(await route(t, 'get_meta_rt', k), `Ok { metadata: Ok(${want}), value: "val" }`);
    answer(await route(t, 'parse_meta_rt', k), `${k}: Ok(${want})`);
  }],
  // Metadata of platform 0.0.9: roc-cbor 0.2.3 wrote a List(U8) as an array, so the JSON has an array of integers.
  ['kv Metadata.parse_legacy reads metadata of platform 0.0.9 (a List(U8) as a JSON array); parse does not', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    const p = `lg-${rand()}`;
    await kv.put(`${p}/a`, 'v', { metadata: { data: [1, 2, 3], n: 1 } });
    answer(await route(t, 'list_legacy', p), `${p}/a: legacy=Ok({ data: [1, 2, 3], n: 1 }) strict=False`);
  }],
  ['kv put_with! ttl_ms rounds up to whole seconds, and expires_ms', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    const k = `ttl-${rand()}`;
    const before = Math.floor(Date.now() / 1000);
    answer(await route(t, 'put_ttl', k, '&v=a&ttl=60001'), 'Ok {}');
    answer(await route(t, 'put_ttl_io', `${k}-io`, '&v=a&ttl=120000'), 'Ok {}');
    const after = Math.floor(Date.now() / 1000);
    const keys = await listed(t, kv, 'ttl-', (ks) => ks.some((x) => x.name === k) && ks.some((x) => x.name === `${k}-io`));
    const at = (name) => keys.find((x) => x.name === name)?.expiration;
    // 60,001 ms is 61 s (rounded up, not 60): the expiration is between `before + 61` and `after + 62`.
    ok(at(k) >= before + 61 && at(k) <= after + 62, `ttl 60,001 ms: expiration ${at(k)}, want ${before + 61} to ${after + 62}`);
    ok(at(`${k}-io`) >= before + 120 && at(`${k}-io`) <= after + 121, `ttl 120,000 ms: expiration ${at(`${k}-io`)}`);
    const e = `${k}-at`;
    const when = Date.now() + 3_600_000 + 1;
    answer(await route(t, 'put_expires', e, `&v=a&expires=${when}`), 'Ok {}');
    const exp = (await kv.list({ prefix: e })).keys[0].expiration;
    eq(exp, Math.floor(when / 1000) + 1, 'expiration (rounded up)');
    // A ttl under 60 s is raised to 60 s (the platform clamps it, MODULES.md 5.2): `Ok`, and an expiration of about 60 s.
    const low = await route(t, 'put_ttl', `${k}-low`, '&v=a&ttl=10000');
    answer(low, 'Ok {}');
    const lowAt = (await kv.list({ prefix: `${k}-low` })).keys[0].expiration;
    ok(lowAt >= before + 60 && lowAt <= after + 61, `ttl 10,000 ms: expiration ${lowAt}, want ${before + 60} to ${after + 61}`);
    return `expiration ${at(k)}; ttl of 10 s: ${low.body}, expiration ${lowAt}`;
  }],
  // PLAN.md 8f: `list!` with metadata.
  ['kv list!: names, expires_ms and typed metadata', async (t) => {
    answer(await route(t, 'list', 'p/'), 'Ok ["p/a:Never:none", "p/b:Never:Ok({ n: 2, tag: \\"bee\\" })", "p/c:Never:none"] Done');
    answer(await route(t, 'list_io', 'p/'), 'Ok ["p/a:Never:none", "p/b:Never:Ok({ n: 2, tag: \\"bee\\" })", "p/c:Never:none"] Done');
    const page1 = await route(t, 'list_page', 'p/', '&v=');
    ok(page1.body.startsWith('Ok ["p/a:Never:none", "p/b:Never:Ok({ n: 2, tag: \\"bee\\" })"] More("'), `page 1: ${page1.body}`);
    const cursor = /More\("([^"]+)"\)/.exec(page1.body)[1];
    answer(await route(t, 'list_page', 'p/', `&v=${q(cursor)}`), 'Ok ["p/c:Never:none"] Done');
    return page1.body.slice(0, 120);
  }],
  ['kv get_or!: the default for a key that is not there, the value for one that is', async (t) => {
    const k = `or-${rand()}`;
    answer(await route(t, 'get_or', k), 'Ok "default"');
    answer(await route(t, 'get_or_io', k), 'Ok "default"');
    await route(t, 'put', k, '&v=hi');
    answer(await route(t, 'get_or', k), 'Ok "hi"');
    answer(await route(t, 'get_or_io', k), 'Ok "hi"');
    answer(await route(t, 'cell_delete'), 'Ok {}');
    answer(await route(t, 'cell_get_or'), 'Ok { big: 0, n: 0, theme: "none" }');
    answer(await route(t, 'cell_get_or_io'), 'Ok { big: 0, n: 0, theme: "none" }');
    // A cell with a value gives the value, not the default.
    await route(t, 'cell_set', '', '&v=stored');
    answer(await route(t, 'cell_get_or'), 'Ok { big: 1152921504606846976, n: 3, theme: "stored" }');
    answer(await route(t, 'cell_get_or_io'), 'Ok { big: 1152921504606846976, n: 3, theme: "stored" }');
    await route(t, 'cell_delete');
    await route(t, 'delete', k);
  }],
  ['kv json of a record with an F64 field: a value is stored, a NaN is BadData and nothing is sent', async (t) => {
    const k = `f64-${rand()}`;
    answer(await route(t, 'f64_put', k, '&v=pi'), 'Ok {}');
    answer(await route(t, 'f64_get', k), 'Ok { name: "pi", ratio: 0.5 }');
    const nan = await route(t, 'f64_put', `${k}-nan`, '&v=nan');
    ok(nan.body.startsWith('Err Infra(BadData("the value does not encode: '), `NaN: ${nan.body}`);
    answer(await route(t, 'f64_get', `${k}-nan`), 'Err NotFound');
    const r = await route(t, 'f64_response', '', '&v=pi');
    eq(r.body, '{"name":"pi","ratio":0.5}', 'Response.from_json of an F64 field');
    const bad = await route(t, 'f64_response', '', '&v=nan');
    eq(bad.status, 500, 'a NaN gives a 500');
    ok(bad.body.startsWith('the response does not encode as JSON: '), `the 500 text: ${bad.body}`);
    await route(t, 'delete', k);
  }],
  ['kv Cell: set!, get!, delete! and the twins', async (t) => {
    // A write of the one key of the Cell. Edge form (`t.edge`, PLAN.md 11c): KV takes one write a second for a key
    // (429 Too Many Requests), so 2 s before each write.
    const write = async (...a) => {
      if (t.edge) await sleep(2000);
      return route(t, ...a);
    };
    await write('cell_delete');
    answer(await route(t, 'cell_get'), 'Err NotFound');
    answer(await write('cell_set', '', '&v=dark'), 'Ok {}');
    answer(await route(t, 'cell_get'), 'Ok { big: 1152921504606846976, n: 3, theme: "dark" }');
    answer(await route(t, 'cell_get_io'), 'Ok { big: 1152921504606846976, n: 3, theme: "dark" }');
    answer(await write('cell_delete'), 'Ok {}');
    answer(await route(t, 'cell_get'), 'Err NotFound');
    answer(await write('cell_set_io', '', '&v=dark'), 'Ok {}');
    answer(await write('cell_delete_io'), 'Ok {}');
    answer(await route(t, 'cell_get_io'), 'Err NotFound');
  }],
  ['kv Cell set_with!: ttl_ms', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    // Edge form (`t.edge`): one write a second for a key (429 Too Many Requests), and a `list` that can be late.
    if (t.edge) await sleep(2000);
    const before = Math.floor(Date.now() / 1000);
    answer(await route(t, 'cell_set_ttl', '', '&v=dark&ttl=90000'), 'Ok {}');
    const exp = (await listed(t, kv, 'cell-prefs', (ks) => ks[0]?.expiration >= before + 88))[0].expiration;
    ok(Math.abs(exp - (before + 90)) <= 2, `expiration ${exp}`);
    if (t.edge) await sleep(2000);
    answer(await route(t, 'cell_set_ttl_io', '', '&v=dark&ttl=120000'), 'Ok {}');
    if (t.edge) await sleep(2000);
    await route(t, 'cell_delete');
  }],
  ['kv get_or!: only NotFound gets the default, a value that does not parse stays BadData', async (t) => {
    const k = `orbad-${rand()}`;
    await route(t, 'put', k, '&v=not-json');
    const r = await route(t, 'get_or_bad', k);
    ok(r.status === 200 && r.body.startsWith('Err Infra(BadData("'), `got ${r.body}`);
    answer(await route(t, 'get_or_bad', `${k}-missing`), 'Ok { big: 0, n: 0, theme: "default" }');
    await route(t, 'delete', k);
  }],
  ['kv F64 field: the twin, put_with! and Cell set! give BadData for a NaN and send nothing, a value is stored', async (t) => {
    const k = `f64b-${rand()}`;
    const bad = (r, what) => ok(r.status === 200 && r.body.startsWith('Err Infra(BadData("the value does not encode: '), `${what}: ${r.body}`);
    answer(await route(t, 'f64_put_io', k, '&v=pi'), 'Ok {}');
    answer(await route(t, 'f64_get', k), 'Ok { name: "pi", ratio: 0.5 }');
    bad(await route(t, 'f64_put_io', `${k}-io`, '&v=nan'), 'put (Io twin)');
    answer(await route(t, 'f64_get', `${k}-io`), 'Err NotFound');
    bad(await route(t, 'f64_put_with', `${k}-w`, '&v=nan'), 'put_with!');
    answer(await route(t, 'f64_get', `${k}-w`), 'Err NotFound');
    answer(await route(t, 'f64_put_with', `${k}-w2`, '&v=ok'), 'Ok {}');
    answer(await route(t, 'f64_get', `${k}-w2`), 'Ok { name: "ok", ratio: 0.5 }');
    answer(await route(t, 'f64_cell_set', '', '&v=cell'), 'Ok {}');
    bad(await route(t, 'f64_cell_set', '', '&v=nan'), 'Cell set!');
    // The stored value is still the one before the NaN.
    answer(await route(t, 'f64_cell_get'), 'Ok { name: "cell", ratio: 0.5 }');
    for (const x of ['', '-io', '-w', '-w2']) await route(t, 'delete', `${k}${x}`);
  }],
  ['kv a NaN is no write: the old value stays', async (t) => {
    const k = `f64c-${rand()}`;
    answer(await route(t, 'f64_put', k, '&v=one'), 'Ok {}');
    ok((await route(t, 'f64_put', k, '&v=nan')).body.startsWith('Err Infra(BadData('), 'NaN put');
    answer(await route(t, 'f64_get', k), 'Ok { name: "one", ratio: 0.5 }');
    await route(t, 'delete', k);
  }],
  ['io recover: NotFound is a value, a BadData goes to the new error, a value stays (one crossing)', async (t) => {
    const k = `rec-${rand()}`;
    const r = await route(t, 'recover', k);
    answer(r, 'Ok "recovered"');
    eq(r.awaits, 1, 'js_await');
    answer(await route(t, 'recover_bad', k), 'Ok recovered');
    await route(t, 'put', k, '&v=hi');
    answer(await route(t, 'recover', k), 'Ok "hi"');
    await route(t, 'put', k, '&v=not-json');
    answer(await route(t, 'recover_bad', k), 'Err Other');
    await route(t, 'delete', k);
  }],
  ['io timeout keeps the error of the operation: NotFound is not TimedOut, a value is Ok', async (t) => {
    const k = `to-${rand()}`;
    const r = await route(t, 'timeout_get', k);
    answer(r, 'NotFound');
    ok(r.ms < 1500, `the sleep of 5 s is aborted: ${r.ms} ms`);
    await route(t, 'put', k, '&v=hi');
    answer(await route(t, 'timeout_get', k), 'Ok "hi"');
    await route(t, 'delete', k);
  }],
  // The clamp of `ttl_ms` (MODULES.md 5.2): under 60 s goes up to 60 s, for `put_with!`, its Io twin and `Kv.Cell.set_with!`; 60 s and more stay.
  ['kv ttl_ms under 60 s is raised to 60 s (put_with!, the Io twin, Cell.set_with!), and 60 s or more is kept', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    const k = `clamp-${rand()}`;
    // `before`: the time of each put (the whole check takes many seconds on the edge).
    let before = 0;
    const put = async (...a) => {
      before = Math.floor(Date.now() / 1000);
      answer(await route(t, ...a), 'Ok {}');
    };
    const inWindow = (e, secs) => e >= before + secs && e <= before + secs + 5;
    const exp = async (name, secs) => (await listed(t, kv, name, (ks) => ks.some((x) => x.name === name && inWindow(x.expiration, secs)))).find((x) => x.name === name)?.expiration;
    const near = (e, secs, what) => ok(e >= before + secs && e <= before + secs + 5, `${what}: expiration ${e}, want about ${before + secs}`);
    for (const [ms, secs] of [[0, 60], [1, 60], [59_999, 60], [60_000, 60], [120_000, 120]]) {
      await put('put_ttl', `${k}-${ms}`, `&v=a&ttl=${ms}`);
      near(await exp(`${k}-${ms}`, secs), secs, `put_with! ttl ${ms}`);
    }
    await put('put_ttl_io', `${k}-io`, '&v=a&ttl=10000');
    near(await exp(`${k}-io`, 60), 60, 'Io twin ttl 10000');
    // Edge form: KV takes one write a second for a key (429 Too Many Requests).
    if (t.edge) await sleep(2000);
    await put('cell_set_ttl', '', '&v=dark&ttl=10000');
    near(await exp('cell-prefs', 60), 60, 'Cell.set_with! ttl 10000');
    if (t.edge) await sleep(2000);
    await put('cell_set_ttl_io', '', '&v=dark&ttl=5000');
    near(await exp('cell-prefs', 60), 60, 'Cell.set_with Io twin ttl 5000');
    await route(t, 'cell_delete');
  }],
];
