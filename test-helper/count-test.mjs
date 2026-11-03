// S3 of research/design-notes/test-helper.md 10: the count rules of TH6 and TH16 in Node (js/test-entry.js), with stand-in
// D1, KV, R2 and queue bindings made of plain objects.
//   node test-helper/count-test.mjs
import { countBinding, kindOf, testEntry, bodyOf, BODY_MAX } from '../js/test-entry.js';

let failed = 0;
const check = (name, cond, why = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : `: ${why}`}`);
  if (!cond) failed++;
};

const realStmts = [];
const stmt = (sql) => {
  const s = { sql, bind: (...a) => stmt(`${sql} ${JSON.stringify(a)}`), all: async () => ({ results: [] }), run: async () => ({}), first: async () => null, raw: async () => [] };
  realStmts.push(s);
  return s;
};
const d1 = () => {
  const db = {
    prepare: (sql) => stmt(sql),
    batch: async (list) => list.map((s) => ({ isReal: realStmts.includes(s) })),
    exec: async () => ({}),
    withSession: (arg) => ({ ...db, bookmark: arg, getBookmark: () => 'b1' }),
  };
  return db;
};
const kv = { get: async () => null, getWithMetadata: async () => ({}), put: async () => {}, delete: async () => {}, list: async () => ({ keys: [] }) };
const r2 = { get: async () => null, head: async () => null, put: async () => ({}), delete: async () => {}, list: async () => ({}), createMultipartUpload: async () => ({}), resumeMultipartUpload: () => ({}) };
const queue = { send: async () => {}, sendBatch: async () => {} };

check('kindOf: d1, kv, r2, queue, other', [kindOf(d1()), kindOf(kv), kindOf(r2), kindOf(queue), kindOf({ fetch() {} })].join() === 'd1,kv,r2,queue,');

// TH6: D1.
const log = [];
const sessions = [];
const db = countBinding(d1(), (op, session) => log.push({ op, session }), (a) => sessions.push(a));
const s = db.prepare('SELECT 1');
const b = s.bind(1, 2);
check('D1: prepare and bind are not calls', log.length === 0, JSON.stringify(log));
await b.all();
await s.first();
await s.run();
await s.raw();
check('D1: all, first, run, raw of a statement are one call each', log.map((c) => c.op).join() === 'all,first,run,raw', JSON.stringify(log));
log.length = 0;
const out = await db.batch([db.prepare('A'), db.prepare('B').bind(1)]);
check('D1: a batch of 2 statements is 1 call', log.length === 1 && log[0].op === 'batch', JSON.stringify(log));
check('D1: batch gets the real statements, not the proxies', out.every((x) => x.isReal), JSON.stringify(out));
log.length = 0;
await db.exec('CREATE TABLE t (a)');
check('D1: exec is 1 call', log.length === 1 && log[0].op === 'exec');
log.length = 0;
// TH16: the session of each call.
const sess = db.withSession('first-primary');
check('D1: withSession is not a call, its argument is recorded', log.length === 0 && sessions.join() === 'first-primary', `${JSON.stringify(log)} ${sessions}`);
await sess.prepare('SELECT 2').all();
await sess.batch([sess.prepare('X')]);
await db.prepare('SELECT 3').all();
check('D1: each call has the session of the session object that made it, else null', JSON.stringify(log) === JSON.stringify([{ op: 'all', session: 'first-primary' }, { op: 'batch', session: 'first-primary' }, { op: 'all', session: null }]), JSON.stringify(log));
check('D1: getBookmark of a session is not a call', (sess.getBookmark(), log.length === 3));

// KV, R2, queue.
const ops = (b, run) => {
  const l = [];
  const c = countBinding(b, (op) => l.push(op), () => {});
  return run(c).then(() => l.join());
};
check('KV: get, getWithMetadata, put, delete, list', (await ops(kv, async (c) => { await c.get('a'); await c.getWithMetadata('a'); await c.put('a', 'b'); await c.delete('a'); await c.list(); })) === 'get,getWithMetadata,put,delete,list');
check('R2: get, head, put, delete, list, createMultipartUpload, resumeMultipartUpload', (await ops(r2, async (c) => { await c.get('a'); await c.head('a'); await c.put('a', 'b'); await c.delete('a'); await c.list(); await c.createMultipartUpload('a'); c.resumeMultipartUpload('a', 'u'); })) === 'get,head,put,delete,list,createMultipartUpload,resumeMultipartUpload');
check('queue: send, sendBatch', (await ops(queue, async (c) => { await c.send(1); await c.sendBatch([]); })) === 'send,sendBatch');
const other = { fetch() {} };
check('a binding of another kind is not wrapped', countBinding(other, () => {}, () => {}) === other);

// testEntry: the clock and the wrap of env (no request number: the calls of other tasks).
const t = testEntry({ token: 'tok', now: 1000, count: ['DB'] });
check('testEntry: now is the start time', t.now() === 1000);
const env = { DB: d1(), KV: kv };
const wrapped = t.wrapEnv(env, { kind: 'Alarm', name: 'Room.alarm', event: {} });
check('testEntry: only the named bindings are wrapped', wrapped.KV === kv && wrapped.DB !== env.DB && env.DB.prepare !== undefined);
const t2 = testEntry({ token: 'tok', count: [] });
check('testEntry: no count, no hooks: env is the same object', t2.wrapEnv(env, { kind: 'Fetch' }) === env);
check('testEntry: now null is the real clock', Math.abs(t2.now() - Date.now()) < 1000);
const seen = [];
const t3 = testEntry({ token: 'tok', count: ['DB'], wrapEnv: (e, i) => (seen.push(['app', i.kind]), e), hooks: { wrapEnv: (e) => (seen.push(['hooks', e.DB !== env.DB]), e) } });
t3.wrapEnv(env, { kind: 'Queue' });
check('TH7: the count, then wrapEnv of the options file, then hooks.wrapEnv (it sees the counted DB)', JSON.stringify(seen) === JSON.stringify([['app', 'Queue'], ['hooks', true]]), JSON.stringify(seen));

// TH21: the body of a queue message in the call record.
const b64 = (a) => Buffer.from(a).toString('base64');
const bodies = [];
const spyQueue = countBinding(queue, (op, session, extra) => bodies.push([op, extra]));
await spyQueue.send({ n: 1 }, { contentType: 'json' });
await spyQueue.sendBatch([{ body: 'hi', contentType: 'text' }, { body: new Uint8Array([1, 2]), contentType: 'bytes' }]);
check('TH21: send records body and contentType', JSON.stringify(bodies[0][1]) === JSON.stringify({ body: { bytes: b64([0xa1, 0x61, 0x6e, 1]), size: 4, value: { n: 1 } }, contentType: 'json' }), JSON.stringify(bodies[0]));
check('TH21: sendBatch records bodies; text is UTF-8; non-CBOR bytes have no value', JSON.stringify(bodies[1][1]) === JSON.stringify({ bodies: [{ bytes: b64('hi'), size: 2, value: 'hi', contentType: 'text' }, { bytes: b64([1, 2]), size: 2, contentType: 'bytes' }] }), JSON.stringify(bodies[1]));
const delays = [];
const spyDelay = countBinding(queue, (op, session, extra) => delays.push(extra));
await spyDelay.send('a', { contentType: 'text', delaySeconds: 30 });
await spyDelay.sendBatch([{ body: 'b', contentType: 'text', delaySeconds: 5 }, { body: 'c', contentType: 'text' }], { delaySeconds: 60 });
await spyDelay.send('d', { contentType: 'text', delaySeconds: 0 });
check('TH21: send keeps delaySeconds', delays[0].delaySeconds === 30, JSON.stringify(delays[0]));
check('TH21: sendBatch keeps delaySeconds of each message and of the batch options; a message with none has none', delays[1].delaySeconds === 60 && delays[1].bodies[0].delaySeconds === 5 && !('delaySeconds' in delays[1].bodies[1]), JSON.stringify(delays[1]));
check('TH21: delaySeconds 0 is kept; a send with no delaySeconds has no key', delays[2].delaySeconds === 0 && !('delaySeconds' in bodies[0][1]), JSON.stringify([delays[2], bodies[0][1]]));
check('TH21: a binary body that is CBOR has the decoded value too', JSON.stringify(bodyOf(new Uint8Array([0xa1, 0x61, 0x6e, 5]))) === JSON.stringify({ bytes: b64([0xa1, 0x61, 0x6e, 5]), size: 4, value: { n: 5 } }));
check('TH21: a BigInt and a Uint8Array in the value are JSON-safe', JSON.stringify(bodyOf({ a: 5n, b: new Uint8Array([9]) }).value) === JSON.stringify({ a: { $bigint: '5' }, b: { $bytes: b64([9]) } }));
const big = bodyOf('x'.repeat(BODY_MAX + 10));
check('TH21: a body over BODY_MAX keeps BODY_MAX bytes, size, truncated, no value', Buffer.from(big.bytes, 'base64').length === BODY_MAX && big.size === BODY_MAX + 10 && big.truncated === true && big.value === undefined, JSON.stringify(big).slice(0, 80));
check('TH20: kindOf: a ratelimit binding', kindOf({ limit: async () => ({ success: true }) }) === 'ratelimit');
const keys = [];
const rl = { limit: async (o) => (keys.push(o.key), { success: true }) };
const tr = testEntry({ token: 'tok', count: [] });
const w1 = tr.wrapEnv({ RL: rl }, { kind: 'Fetch' });
await w1.RL.limit({ key: 'k' });
check('TH20: the key of a limit call has the generation as a prefix', keys[0] === '0:k', keys[0]);

console.log(`${failed ? 'FAIL' : 'PASS'} count-test: ${failed} failed`);
process.exit(failed ? 1 : 0);
