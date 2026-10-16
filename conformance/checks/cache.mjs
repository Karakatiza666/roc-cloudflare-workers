// `Cache` (MODULES.md 5.4): routes of conformance/CacheRoutes.roc, on the local Cache API of Miniflare. The default cache
// and a named one. Edge part (PLAN.md 11c): the cache of one data center, and the rules of what is stored.
import { answer, eq, ok } from '../assert.mjs';

export const options = {};

const q = encodeURIComponent;
const key = (name) => q(`http://example.com/${name}`);
const put = (t, name, extra = '') => t.get(`/cache/put?url=${key(name)}&text=hello&cc=max-age%3D60${extra}`);

export const checks = [
  // OP7: `cache.match` gives `undefined` for a key that is not cached: `Fields` of it is `undefined`, so `NotFound`.
  ['cache get! of a missing key is NotFound', async (t) => answer(await t.get(`/cache/get?url=${key('missing')}`), 'Err NotFound')],
  ['cache put! and get!', async (t) => {
    answer(await put(t, 'a'), 'Ok put');
    const r = await t.get(`/cache/get?url=${key('a')}`);
    answer(r, 'Ok 200 cc=max-age=60 text=hello');
    eq(r.waits, 2, 'waits');
  }],
  ['cache put (Io twin) and get (Io twin)', async (t) => {
    answer(await t.get(`/cache/put_io?url=${key('b')}&text=twin&cc=max-age%3D60`), 'Ok put');
    answer(await t.get(`/cache/get_io?url=${key('b')}`), 'Ok 200 cc=max-age=60 text=twin');
    answer(await t.get(`/cache/get_io?url=${key('missing')}`), 'Err NotFound');
  }],
  ['cache put! of a 206 response is CacheErr', async (t) => {
    const r = await put(t, 'partial', '&status=206');
    ok(r.body.startsWith('Err CacheErr(') && r.body.includes('206'), `got ${r.body}`);
    const r2 = await t.get(`/cache/put_io?url=${key('partial')}&text=x&status=206&cc=max-age%3D60`);
    ok(r2.body.startsWith('Err CacheErr('), `twin: ${r2.body}`);
  }],
  ['cache put! of a Stream body', async (t) => {
    answer(await t.get(`/cache/put_stream?url=${key('s')}&from=${q(`${t.server}/hello`)}`), 'Ok put');
    answer(await t.get(`/cache/get?url=${key('s')}`), 'Ok 200 cc=max-age=60 text=hello');
  }],
  ['cache delete!', async (t) => {
    await put(t, 'd');
    answer(await t.get(`/cache/delete?url=${key('d')}`), 'Ok deleted');
    answer(await t.get(`/cache/get?url=${key('d')}`), 'Err NotFound');
  }],
  ['cache delete! of a key that is not cached is NotFound', async (t) => {
    answer(await t.get(`/cache/delete?url=${key('never')}`), 'Err NotFound');
    answer(await t.get(`/cache/delete_io?url=${key('never')}`), 'Err NotFound');
  }],
  ['cache delete (Io twin)', async (t) => {
    await put(t, 'd2');
    answer(await t.get(`/cache/delete_io?url=${key('d2')}`), 'Ok deleted');
  }],
  ['cache named is a cache of its own', async (t) => {
    answer(await t.get(`/cache/put?name=mine&url=${key('n')}&text=named&cc=max-age%3D60`), 'Ok put');
    answer(await t.get(`/cache/get?name=mine&url=${key('n')}`), 'Ok 200 cc=max-age=60 text=named');
    answer(await t.get(`/cache/get?url=${key('n')}`), 'Err NotFound');
    answer(await t.get(`/cache/delete?name=mine&url=${key('n')}`), 'Ok deleted');
  }],
];
