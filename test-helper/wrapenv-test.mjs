// S2 of research/design-notes/test-helper.md 10: the shim option `wrapEnv` (TH11) in Node, with the stand-in class of
// `cloudflare:workers` (bench/cf-node.mjs) and the helper app (test-helper/app/main.roc, production host).
//   node test-helper/wrapenv-test.mjs <helper.wasm>
// Checks: one call of `wrapEnv` for each event of each kind (`Fetch`, `Scheduled`, `Queue`, `Init`, `Alarm`, `Rpc`, `Socket`),
// with `info` { kind, name, event }; the binding check sees the raw `env`; the result of `wrapEnv` is the root `env` of the task;
// a throw in `wrapEnv` fails the event; a bad value of the option fails at `makeHandler`.
import { readFileSync } from 'node:fs';
import { makeHandler, objectClass } from '../bench/cf-node.mjs';

const wasm = new WebAssembly.Module(readFileSync(process.argv[2] ?? '.cache/th/helper.wasm'));
let failed = 0;
const check = (name, cond, why = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : `: ${why}`}`);
  if (!cond) failed++;
};

// Stand-in bindings: class instances with the functions that the binding check of each kind needs (js/bindings.js).
class D1 { prepare() { return { bind: () => this, all: async () => ({ results: [] }), first: async () => null, run: async () => ({}) }; } async batch() { return []; } }
class Kv { constructor() { this.puts = []; } async get() { return null; } async put(k, v) { this.puts.push([k, v]); } async getWithMetadata() { return { value: null }; } async list() { return { keys: [] }; } async delete() {} }
class R2 { async head() { return null; } async put() { return {}; } async createMultipartUpload() {} async get() { return null; } }
class Q { async send() {} async sendBatch() {} }
class Ns { idFromName() {} newUniqueId() {} }
const envOf = () => ({ DB: new D1(), KV: new Kv(), BUCKET: new R2(), JOBS: new Q(), LIMITER: { limit: async () => ({ success: true }) }, ROOMS: new Ns() });

const seen = [];
let mode = 'count';
const wrapEnv = (env, info) => {
  seen.push({ kind: info.kind, name: info.name, hasEvent: info.event !== undefined, raw: env });
  if (mode === 'throw') throw new Error('wrap failed');
  if (mode === 'swap') return { ...env, KV: swapKv };
  return env;
};
const swapKv = new Kv();
const logs = [];
const Room = objectClass('Room');
const H = makeHandler(wasm, { wrapEnv, log: (t) => logs.push(t) });
const env = envOf();
const ctx = { waitUntil: () => {} };
const h = new H(ctx, env);

// Fetch.
let res = await h.fetch(new Request('http://x/now'));
check('Fetch: one call, kind Fetch, name fetch, event is the request', seen.length === 1 && seen[0].kind === 'Fetch' && seen[0].name === 'fetch' && seen[0].hasEvent, JSON.stringify(seen));
check('Fetch: wrapEnv gets the raw env object', seen[0].raw === env);
check('Fetch: the answer is the app answer', res.status === 200, `status ${res.status}`);

// Scheduled.
seen.length = 0;
await h.scheduled({ cron: '*/5 * * * *', scheduledTime: 1767225600000, noRetry() {} });
check('Scheduled: one call, kind Scheduled', seen.length === 1 && seen[0].kind === 'Scheduled' && seen[0].name === 'scheduled', JSON.stringify(seen.map((s) => [s.kind, s.name])));

// Queue.
seen.length = 0;
const msg = { id: '1', timestamp: new Date(), body: { n: 1 }, attempts: 1, ack() {}, retry() {} };
await h.queue({ queue: 'jobs', messages: [msg], ackAll() {}, retryAll() {} }).catch((e) => logs.push(String(e)));
check('Queue: one call, kind Queue', seen.length === 1 && seen[0].kind === 'Queue' && seen[0].name === 'queue', JSON.stringify(seen.map((s) => [s.kind, s.name])));

// The object class: Init (constructor), Rpc, Alarm, Socket. The ctx of an object: an id, a SQLite storage stand-in.
const sql = { databaseSize: 0, exec: () => ({ toArray: () => [], rowsRead: 0, rowsWritten: 0, columnNames: [], raw: () => [][Symbol.iterator](), [Symbol.iterator]: () => [][Symbol.iterator]() }) };
let inits = [];
const octx = { id: { toString: () => 'room-1' }, storage: { sql, setAlarm: async () => {}, getAlarm: async () => null, deleteAlarm: async () => {} }, blockConcurrencyWhile: (fn) => inits.push(fn().catch((e) => logs.push(String(e)))), waitUntil: () => {}, getWebSockets: () => [] };
seen.length = 0;
const o = new Room(octx, env);
await Promise.all(inits);
check('Init: one call, kind Init, name Room.init', seen.length === 1 && seen[0].kind === 'Init' && seen[0].name === 'Room.init', JSON.stringify(seen.map((s) => [s.kind, s.name])));
seen.length = 0;
const bumped = await o.bump({ by: 4 }).catch((e) => `throw ${e.message}`);
check('Rpc: one call, kind Rpc, name Room.bump', seen.length === 1 && seen[0].kind === 'Rpc' && seen[0].name === 'Room.bump', JSON.stringify(seen.map((s) => [s.kind, s.name])));
check('Rpc: the reply of the app', JSON.stringify(bumped) === JSON.stringify({ Ok: 4 }), JSON.stringify(bumped));
seen.length = 0;
mode = 'swap';
const rawPuts = env.KV.puts.length;
await o.alarm({ retryCount: 0, isRetry: false }).catch((e) => logs.push(String(e)));
check('Alarm: one call, kind Alarm, name Room.alarm', seen.length === 1 && seen[0].kind === 'Alarm' && seen[0].name === 'Room.alarm', JSON.stringify(seen.map((s) => [s.kind, s.name])));
check('Alarm: the app writes to the KV that wrapEnv gave (the root env of the task), not the raw one', swapKv.puts.length === 1 && env.KV.puts.length === rawPuts, `wrapped ${swapKv.puts.length}, raw ${env.KV.puts.length - rawPuts}; logs ${logs.slice(-2)}`);
mode = 'count';
seen.length = 0;
const ws = { deserializeAttachment: () => null, serializeAttachment() {} };
await o.webSocketMessage(ws, 'hi').catch((e) => logs.push(String(e)));
check('Socket: one call, kind Socket, name Room.webSocketMessage', seen.length === 1 && seen[0].kind === 'Socket' && seen[0].name === 'Room.webSocketMessage', JSON.stringify(seen.map((s) => [s.kind, s.name])));

// A throw in wrapEnv fails the event as a throw of the event.
mode = 'throw';
const thrown = await h.fetch(new Request('http://x/now')).then(() => 'no throw', (e) => e.message);
check('a throw in wrapEnv is a throw of the event', thrown === 'wrap failed', thrown);
mode = 'count';

// The binding check sees the raw env: a raw env with no DB fails, also when wrapEnv would add it.
const H2 = makeHandler(wasm, { wrapEnv: (e) => ({ ...e, DB: new D1() }), log: () => {} });
const noDb = envOf();
delete noDb.DB;
const r2 = await new H2(ctx, noDb).fetch(new Request('http://x/now')).then(() => 'no throw', (e) => e.message);
check('the binding check sees the raw env, not the result of wrapEnv', /env has no DB/.test(r2), r2);

// The option check.
const bad = (() => { try { makeHandler(wasm, { wrapEnv: 3 }); return 'no throw'; } catch (e) { return e.message; } })();
check('wrapEnv must be a function', /option "wrapEnv" must be a function/.test(bad), bad);

console.log(`${failed ? 'FAIL' : 'PASS'} wrapenv-test: ${failed} failed`);
process.exit(failed ? 1 : 0);
