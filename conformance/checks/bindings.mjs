// The check of `Worker.new bindings` at load (MODULES.md 3, js/bindings.js): the app (conformance/app.roc) declares the D1
// database DB, the KV namespace KV and the object namespace COUNTERS (class Counter). Each case is a second Miniflare with
// `t.startBare` (no binding added) that must not serve, and the error has the clear text. The manifest cases (a name twice,
// a class that is not in objects) need other apps: bench/bindings-test.mjs.
import { eq, ok } from '../assert.mjs';

export const options = {};

const counters = { COUNTERS: { className: 'Counter', useSQLite: true } };
const quiet = () => {};

// The text of the failure: the error of the load (workerd with `env` at global scope), or the error of the first request.
async function failure(t, opts) {
  const lines = [];
  const mf = t.startBare({ handleStructuredLogs: (l) => lines.push(String(l.message)), ...opts });
  try {
    try {
      await mf.ready;
    } catch (e) {
      return String(e.message);
    }
    const r = await mf.dispatchFetch('http://localhost/shim/ops');
    const body = await r.text();
    ok(r.status !== 200, `the app served with a bad binding: ${r.status} ${body.slice(0, 100)}`);
    return `${body}\n${lines.join('\n')}`;
  } finally {
    await mf.dispose().catch(quiet);
  }
}

export const checks = [
  ['bindings load: a binding that env does not have: the message names it and the Wrangler part', async (t) => {
    const text = await failure(t, { kvNamespaces: ['KV'], durableObjects: counters });
    ok(text.includes('DB (d1): env has no DB'), `no "DB (d1): env has no DB" in: ${text.slice(0, 400)}`);
    ok(text.includes('[[d1_databases]]'), `no Wrangler part in: ${text.slice(0, 400)}`);
    ok(!text.includes('KV (kv)'), 'KV is there, so it must not be named');
    return 'DB (d1): env has no DB';
  }],
  ['bindings load: DB is a KV namespace (a wrong kind): the message says it is not a D1 database', async (t) => {
    const text = await failure(t, { kvNamespaces: ['KV', 'DB'], durableObjects: counters });
    ok(text.includes('DB (d1): env.DB is not a D1 database (it has no prepare)'), `no kind message in: ${text.slice(0, 400)}`);
    return 'env.DB is not a D1 database';
  }],
  ['bindings load: KV is a D1 database (the other wrong kind)', async (t) => {
    const text = await failure(t, { d1Databases: ['DB', 'KV'], durableObjects: counters });
    ok(text.includes('KV (kv): env.KV is not a KV namespace'), `no kind message in: ${text.slice(0, 400)}`);
    return 'env.KV is not a KV namespace';
  }],
  ['bindings load: a namespace that env does not have', async (t) => {
    const text = await failure(t, { d1Databases: ['DB'], kvNamespaces: ['KV'] });
    ok(text.includes('COUNTERS (object): env has no COUNTERS'), `no message in: ${text.slice(0, 400)}`);
    ok(text.includes('[[durable_objects.bindings]]'), `no Wrangler part in: ${text.slice(0, 400)}`);
    return 'COUNTERS (object): env has no COUNTERS';
  }],
  ['bindings load: all there, the app serves', async (t) => {
    const mf = t.startBare({ d1Databases: ['DB'], kvNamespaces: ['KV'], durableObjects: counters });
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const r = await mf.dispatchFetch(`${base}/shim/ops`);
      eq(`${r.status} ${await r.text()}`, '200 Ok(Int(42))', 'the answer');
    } finally {
      await mf.dispose();
    }
  }],
];
