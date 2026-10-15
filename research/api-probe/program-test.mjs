// node program-test.mjs: programs against a fake D1 binding and a class instance.
import assert from 'node:assert/strict';
import { encode, decode } from './codec.mjs';
import { run, Refs } from './program.mjs';

class Stmt { constructor(sql) { this.sql = sql; this.args = []; } bind(...a) { this.args = a; return this; } async raw() { return [['n'], [this.args[0] * 2n]]; } }
class Obj2 { get size() { return 42; } get uploaded() { return new Date(1000); } }
let crossings = 0;
const env = { DB: { prepare: (sql) => new Stmt(sql) }, BUCKET: { get: async () => new Obj2() } };
const roots = { env, global: globalThis };
const refs = new Refs();
const go = async (prog, mode = 'await') => { crossings++; const r = await run(encode(prog), roots, refs, mode); return { status: r.status, v: decode(r.bytes, (id) => ({ ref: id })) }; };

// One crossing for prepare, bind and raw (OP1, OP2).
let r = await go([
  ['get', ['root', 'env'], 'DB'],
  ['call', ['slot', 0], 'prepare', [['lit', 'select ?']]],
  ['call', ['slot', 1], 'bind', [['lit', 21n]]],
  ['call', ['slot', 2], 'raw', []],
]);
assert.deepEqual(r, { status: 0, v: [['n'], [42n]] });
assert.equal(crossings, 1);

// A class instance becomes a ref (J7). Fields reads getters, and a Date becomes ms (J4).
r = await go([['get', ['root', 'env'], 'BUCKET'], ['call', ['slot', 0], 'get', [['lit', 'k']]]]);
assert.equal(r.status, 0);
const id = r.v.ref;
r = await go([['fields', { $ref: id }, ['size', 'uploaded']]]);
assert.deepEqual(r.v, { size: 42, uploaded: 1000 });

// A promise in call! is status 2. An unknown root is status 3. A throw is status 1.
assert.equal((await go([['call', ['root', 'env'], 'nothing', []]], 'call')).status, 1);
assert.equal((await go([['get', ['root', 'env'], 'BUCKET'], ['call', ['slot', 0], 'get', [['lit', 'k']]]], 'call')).status, 2);
assert.equal((await go([['get', ['root', 'nope'], 'x']])).status, 3);

// Array of slots: one crossing for a D1 batch (6.2).
env.DB.batch = async (stmts) => stmts.map((st) => st.sql);
r = await go([
  ['get', ['root', 'env'], 'DB'],
  ['call', ['slot', 0], 'prepare', [['lit', 'insert a']]],
  ['call', ['slot', 0], 'prepare', [['lit', 'insert b']]],
  ['array', [['slot', 1], ['slot', 2]]],
  ['call', ['slot', 0], 'batch', [['slot', 3]]],
]);
assert.deepEqual(r, { status: 0, v: ['insert a', 'insert b'] });

// Record with a slot as a field.
r = await go([['get', ['root', 'env'], 'DB'], ['record', [['db', ['slot', 0]], ['n', ['lit', 1]]]], ['fields', ['slot', 1], ['n']]]);
assert.deepEqual(r, { status: 0, v: { n: 1 } });

// Par: two branches that each wait 100 ms take about 100 ms in one crossing (OP6).
const sleep = (ms, v) => new Promise((ok) => setTimeout(() => ok(v), ms));
roots.t = { sleep, fail: async () => { throw new TypeError('boom'); } };
let t0 = performance.now();
r = await go([['par', [[['call', ['root', 't'], 'sleep', [['lit', 100], ['lit', 'a']]]], [['call', ['root', 't'], 'sleep', [['lit', 100], ['lit', 'b']]]]]]]);
const ms = performance.now() - t0;
assert.deepEqual(r.v, [[0, 'a'], [0, 'b']]);
assert.ok(ms < 160, `par took ${ms} ms`);

// A throw in a branch is that branch's status 1. A bad root in a branch is status 3 for the program.
r = await go([['par', [[['call', ['root', 't'], 'sleep', [['lit', 1], ['lit', 'a']]]], [['call', ['root', 't'], 'fail', []]]]]]);
assert.equal(r.status, 0);
assert.deepEqual(r.v[0], [0, 'a']);
assert.equal(r.v[1][0], 1);
assert.equal((await go([['par', [[['get', ['root', 'nope'], 'x']]]]])).status, 3);

// Start keeps the promise (OP1): Promise.all over two started calls, and in call! a kept promise is a ref.
r = await go([
  ['start', ['root', 't'], 'sleep', [['lit', 50], ['lit', 1]]],
  ['start', ['root', 't'], 'sleep', [['lit', 50], ['lit', 2]]],
  ['array', [['slot', 0], ['slot', 1]]],
  ['get', ['root', 'global'], 'Promise'],
  ['call', ['slot', 3], 'all', [['slot', 2]]],
]);
assert.deepEqual(r, { status: 0, v: [1, 2] });
r = await go([['start', ['root', 't'], 'sleep', [['lit', 1], ['lit', 1]]], ['keep', ['slot', 0]]], 'call');
assert.equal(r.status, 0);
assert.ok(r.v.ref > 0);

// J1: a BigInt outside i64 is status 1. J3: a cycle is status 1.
roots.t.big = () => 2n ** 64n;
const cyc = {}; cyc.self = cyc;
roots.t.cyc = () => cyc;
assert.equal((await go([['call', ['root', 't'], 'big', []]])).status, 1);
assert.equal((await go([['call', ['root', 't'], 'cyc', []]])).status, 1);
let deep = 1; for (let i = 0; i < 100; i++) deep = [deep];
roots.t.deep = () => deep;
assert.equal((await go([['call', ['root', 't'], 'deep', []]])).status, 1);

// Refs of a task go at its end (RS1).
refs.clear();
assert.throws(() => refs.get(id));
console.log('programs: pass');
