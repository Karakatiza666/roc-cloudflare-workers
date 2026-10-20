// `Response.after` (MODULES.md 4, API.md 10.2): routes of conformance/AfterRoutes.roc. The Worker `fetch!` and the named entry
// point `After` (the `fetch!` of an object is in checks/objects.mjs). The work writes keys of the namespace `KV` (checks/kv.mjs).
import { answer, eq, ok } from '../assert.mjs';

const self = Symbol.for('miniflare.kCurrentWorker');
export const options = { kvNamespaces: ['KV'], serviceBindings: { AFTER: { name: self, entrypoint: 'After' } } };

const rand = () => Math.random().toString(36).slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The value of a key, polled until it is there (or 6 s).
const until = async (kv, key) => {
  for (let i = 0; i < 120; i++) {
    const v = await kv.get(key);
    if (v !== null) return v;
    await sleep(50);
  }
  return null;
};

// The slow fetch of the work takes 2 s: the response must come long before, and the key must be written after it.
const early = async (t, route) => {
  const kv = await t.mf.getKVNamespace('KV');
  const id = rand();
  const t0 = Date.now();
  const r = await t.get(`/after/${route}?id=${id}&url=${encodeURIComponent(`${t.server}/slow`)}`);
  const ms = Date.now() - t0;
  answer(r, 'early');
  ok(ms < 1200, `the response came after ${ms} ms: the work ran before it`);
  eq(await kv.get(`after-${id}`), null, 'the key at the response');
  eq(await until(kv, `after-${id}`), 'done', 'the effect of the work');
  return `${ms} ms`;
};

const failing = async (t, route, tag) => {
  const id = rand();
  answer(await t.get(`/after/${route}?id=${id}`), 'ok');
  let line;
  for (let i = 0; i < 50 && !line; i++) {
    line = t.logs.find((l) => l.message.includes(': after respond: failed:') && l.message.includes(id));
    if (!line) await sleep(50);
  }
  ok(line, `no log line "${tag}: after respond: failed: ..." with ${id}`);
  eq(line.message.trim(), `${tag}: after respond: failed: Boom("${id}")`, 'the log line');
  return line.message.trim();
};

export const checks = [
  ['after: Response.after in a Worker fetch! answers before the work ends, and the work runs after', (t) => early(t, 'slow')],
  ['after: Response.after in a named entry point fetch! answers before the work ends, and the work runs after', (t) => early(t, 'entry')],
  ['after: two after calls run in order', async (t) => {
    const kv = await t.mf.getKVNamespace('KV');
    const id = rand();
    answer(await t.get(`/after/two?id=${id}`), 'first');
    eq(await until(kv, `after-${id}-b`), 'one', 'the second work saw the key of the first');
  }],
  // The text of the `Response.after` docs: `<tag>: after respond: failed: <Str.inspect(e)>` (the error is `Boom(id)`).
  ['after: a failing work gives the log line and the client still got 200', (t) => failing(t, 'fail', 'fetch')],
  ['after: a failing work in a named entry point gives the log line with the name of the entry point', (t) => failing(t, 'entry_fail', 'After.fetch')],
];
