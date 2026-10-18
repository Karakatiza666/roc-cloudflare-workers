// `Vectorize` (MODULES.md 13): routes of conformance/VectorizeRoutes.roc on the stub `STUB_VECTORIZE` of
// conformance/bindings.js (Vectorize has no local form): an in-memory index that records each call.
import { answer, eq, ok } from '../assert.mjs';
import { canon } from '../canon.mjs';

const calls = async (t) => JSON.parse((await t.get('/__stub_calls')).body);
const reset = (t) => t.get('/__stub_reset');
const sent = async (t, method) => {
  const c = (await calls(t)).filter((x) => x.method === method);
  eq(c.length, 1, `the number of ${method} calls`);
  return c[0].args;
};

const VECTORS = [
  { id: 'a', values: [0.5, 1.5], metadata: { genre: 'rock', year: 1999 } },
  { id: 'b', values: [1, 2], namespace: 'n1' },
  { id: 'c', values: [3], namespace: 'n1', metadata: { genre: 'jazz', year: 1960 } },
];

export const checks = [
  ['vectorize upsert!, upsert (Io twin): the vectors, with metadata and namespace only where the app gives them', async (t) => {
    for (const p of ['upsert', 'upsert_io']) {
      await reset(t);
      const r = await t.get(`/vectorize/${p}`);
      answer(r, 'Ok up-3');
      eq(r.awaits, 1, 'js_await');
      eq(canon(await sent(t, 'upsert')), canon([VECTORS]), p);
    }
  }],
  ['vectorize insert!, insert (Io twin): the same vectors; an id that exists keeps its vector', async (t) => {
    for (const p of ['insert', 'insert_io']) {
      await reset(t);
      answer(await t.get(`/vectorize/${p}`), 'Ok in-3');
      eq(canon(await sent(t, 'insert')), canon([VECTORS]), p);
    }
    answer(await t.get('/vectorize/insert_changed'), 'Ok in-1');
    answer(await t.get('/vectorize/get'), 'count=2 [a values=0.5,1.5 ns=- meta=rock/1999] [b values=1,2 ns=n1 meta=-]');
  }],
  ['vectorize query!, query (Io twin): the matches with ids and scores, no values and no metadata by default', async (t) => {
    for (const p of ['query', 'query_io']) {
      await reset(t);
      await t.get('/vectorize/upsert');
      const r = await t.get(`/vectorize/${p}`);
      answer(r, 'count=3 [a score=1 values= ns=- meta=-] [b score=0.5 values= ns=n1 meta=-] [c score=0.3333333333333333 values= ns=n1 meta=-]');
      eq(r.awaits, 1, 'js_await');
      eq(canon(await sent(t, 'query')), canon([[0.1, 0.2], {}]), p);
    }
  }],
  ['vectorize query_with!, query_with (Io twin): all options, the typed metadata and the values come back', async (t) => {
    for (const p of ['query_with', 'query_with_io']) {
      await reset(t);
      await t.get('/vectorize/upsert');
      answer(await t.get(`/vectorize/${p}?k=2&ns=n1&genre=jazz`), 'count=1 [c score=1 values=3 ns=n1 meta=jazz/1960]');
      eq(canon(await sent(t, 'query')), canon([[0.1, 0.2], { topK: 2, namespace: 'n1', returnValues: true, returnMetadata: 'all', filter: { genre: 'jazz' } }]), p);
    }
  }],
  ['vectorize query_with!: an option that the app leaves out is not sent', async (t) => {
    await reset(t);
    await t.get('/vectorize/upsert');
    answer(await t.get('/vectorize/query_with_none'), 'count=3 [a score=1 values= ns=- meta=-] [b score=0.5 values= ns=n1 meta=-] [c score=0.3333333333333333 values= ns=n1 meta=-]');
    eq(canon((await sent(t, 'query'))[1]), '{}');
  }],
  ['vectorize query_with!: return_metadata Indexed and None', async (t) => {
    await reset(t);
    await t.get('/vectorize/upsert');
    answer(await t.get('/vectorize/query_with_indexed'), 'count=3 [a score=1 values= ns=- meta=rock/1999] [b score=0.5 values= ns=n1 meta=-] [c score=0.3333333333333333 values= ns=n1 meta=jazz/1960]');
    answer(await t.get('/vectorize/query_with_nometa'), 'count=3 [a score=1 values= ns=- meta=-] [b score=0.5 values= ns=n1 meta=-] [c score=0.3333333333333333 values= ns=n1 meta=-]');
    const q = (await calls(t)).filter((x) => x.method === 'query');
    eq(canon(q.map((x) => x.args[1])), canon([{ returnMetadata: 'indexed' }, { returnValues: false, returnMetadata: 'none' }]));
  }],
  ['vectorize get!, get (Io twin): the vectors that exist, with typed metadata', async (t) => {
    for (const p of ['get', 'get_io']) {
      await reset(t);
      await t.get('/vectorize/upsert');
      answer(await t.get(`/vectorize/${p}`), 'count=2 [a values=0.5,1.5 ns=- meta=rock/1999] [b values=1,2 ns=n1 meta=-]');
      eq(canon(await sent(t, 'getByIds')), canon([['a', 'b', 'zz']]), p);
    }
  }],
  ['vectorize delete!, delete (Io twin): the ids go to the binding, the vectors are gone', async (t) => {
    for (const p of ['delete', 'delete_io']) {
      await reset(t);
      await t.get('/vectorize/upsert');
      answer(await t.get(`/vectorize/${p}`), 'Ok del-2');
      eq(canon(await sent(t, 'deleteByIds')), canon([['a', 'zz']]), p);
      answer(await t.get('/vectorize/get'), 'count=1 [b values=1,2 ns=n1 meta=-]');
    }
  }],
  ['vectorize query_with!: metadata that does not fit the type of the index is BadData with the id', async (t) => {
    await reset(t);
    await t.get('/vectorize/upsert');
    const r = await t.get('/vectorize/query_wrong');
    ok(r.status === 200 && r.body.startsWith('BadData vector a: the metadata does not fit the type'), `got ${r.status} ${r.body}`);
  }],
  ['vectorize query_with!, get!: a result above 1 MiB is TooLarge, query_with! with max_bytes of 2 MB gives it', async (t) => {
    answer(await t.get('/vectorize/query_big'), 'TooLarge');
    answer(await t.get('/vectorize/get_big'), 'TooLarge');
    answer(await t.get('/vectorize/query_big_max'), 'count=1 genre_len=1200000');
  }],
  ['vectorize query!: a binding that is not in the config is VectorizeErr', async (t) => answer(await t.get('/vectorize/missing'), 'VectorizeErr TypeError: Cannot read properties of undefined (reading \'query\')')],
  ['vectorize an F64 field in the metadata is sent; a NaN is BadData and no call is made (and the Io twin)', async (t) => {
    await reset(t);
    answer(await t.get('/vectorize/upsert_f64'), 'Ok up-1');
    eq(canon(await sent(t, 'upsert')), canon([[{ id: 'f', values: [1], metadata: { score: 0.25 } }]]), 'the F64 metadata');
    for (const p of ['upsert_nan', 'insert_nan']) {
      await reset(t);
      const r = await t.get(`/vectorize/${p}`);
      ok(r.status === 200 && r.body.startsWith('BadData the metadata does not encode: '), `${p}: ${r.body}`);
      eq(r.awaits, 0, `${p}: no crossing`);
      eq((await calls(t)).length, 0, `${p}: no call`);
    }
  }],
];
