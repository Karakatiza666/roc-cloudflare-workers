// S3 of research/design-notes/test-helper.md 10: the count rules of TH6 and TH16 in Node (js/test-entry.js), with stand-in
// D1, KV, R2 and queue bindings made of plain objects.
//   node test-helper/count-test.mjs
import { countBinding, kindOf, testEntry } from '../js/test-entry.js';

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

console.log(`${failed ? 'FAIL' : 'PASS'} count-test: ${failed} failed`);
process.exit(failed ? 1 : 0);
