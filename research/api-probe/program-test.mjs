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

// Refs of a task go at its end (RS1).
refs.clear();
assert.throws(() => refs.get(id));
console.log('programs: pass');
