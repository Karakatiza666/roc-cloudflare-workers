// node bench/program-test.mjs: the program interpreter (js/program.js), the result block (js/bridge.js `writeResult`)
// and the platform helpers (js/helpers.js), against fakes, with no wasm (API.md 6.2, 6.4, 11). Statuses 0 to 3.
import assert from 'node:assert/strict';
import { runAwait, runCall, statusOf, errorOf, BadProgram, PromiseInCall } from '../js/program.js';
import { writeResult } from '../js/bridge.js';
import { makeHelpers, makePins } from '../js/helpers.js';
import { Refs, fromJs, Kept } from '../js/values.js';

let count = 0, failed = 0;
async function test(name, f) {
  count++;
  try {
    await f();
    console.log(`ok    ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL  ${name}\n        ${String(e?.stack ?? e).split('\n').slice(0, 3).join('\n        ')}`);
  }
}

const sleep = (ms, signal) => new Promise((res, rej) => {
  const t = setTimeout(() => res(ms), ms);
  signal?.addEventListener('abort', () => { clearTimeout(t); rej(signal.reason); }, { once: true });
});
class Stmt { constructor(sql) { this.sql = sql; this.args = []; } bind(...a) { this.args = a; return this; } async raw() { return [[this.sql, ...this.args]]; } get size() { return this.args.length; } }
const env = { DB: { prepare: (sql) => new Stmt(sql) }, NAME: 'env-name' };
const ctxOf = (extra = {}) => {
  const ctl = new AbortController();
  const roots = { env, ctx: { id: 'ctx' }, event: { url: 'u' }, global: globalThis, ops: { sleep, nil: () => null, boom: () => { throw new RangeError('boom'); }, reject: async () => { throw new TypeError('no'); }, throwText: () => { throw 'text'; } }, signal: ctl.signal, ...extra };
  const c = { roots, refs: new Refs(), signal: ctl.signal, ctl };
  roots.pf = makeHelpers(undefined, c, { pins: makePins(2), log: (t) => logs.push(t) }, null);
  return c;
};
const logs = [];
// Status and value as the bridge makes them.
const run = async (ops, mode = 'await', c = ctxOf()) => {
  try { return [0, mode === 'await' ? await runAwait(ops, c) : runCall(ops, c)]; } catch (e) { return [statusOf(e), errorOf(e)]; }
};
const root = (n) => ['root', n], slot = (n) => ['slot', n], lit = (v) => ['lit', v];

await test('ops: get, call, new, fields (a getter of a class), set, array, record; the last slot is the value', async () => {
  const [s, v] = await run([['get', root('env'), 'DB'], ['call', slot(0), 'prepare', [lit('select ?')]], ['call', slot(1), 'bind', [lit(7), lit('x')]], ['call', slot(2), 'raw', []]]);
  assert.equal(s, 0);
  assert.deepEqual(v, [['select ?', 7, 'x']]);
  const [, f] = await run([['get', root('env'), 'DB'], ['call', slot(0), 'prepare', [lit('q')]], ['call', slot(1), 'bind', [lit(1), lit(2)]], ['fields', slot(2), ['size', 'sql']]]);
  assert.deepEqual(f, { size: 2, sql: 'q' });
  const [, d] = await run([['get', root('global'), 'Date'], ['new', root('global'), 'Date', [lit(5)]]]);
  assert.equal(d.getTime(), 5);
  const o = {};
  const [ss, sv] = await run([['set', ['ref', o], 'k', lit(3)]]);
  assert.equal(ss, 0); assert.equal(sv, undefined); assert.equal(o.k, 3);
  const [, a] = await run([['get', root('env'), 'NAME'], ['array', [slot(0), lit(null)]], ['record', [['n', slot(0)], ['list', slot(1)]]]]);
  assert.deepEqual(a, { n: 'env-name', list: ['env-name', null] });
});
await test('OP2: a slot keeps the JS object (no conversion between ops); keep makes a Ref of any value (Kept)', async () => {
  const [, v] = await run([['get', root('env'), 'DB'], ['keep', slot(0)]]);
  assert.ok(v instanceof Kept); assert.equal(v.value, env.DB);
  const [, p] = await run([['keep', root('ctx')], ['array', [slot(0)]]]);
  assert.deepEqual(p, [{ id: 'ctx' }]);
});
await test('OP3: roots env, ctx, event, global, pf, ops, signal; an unknown root is status 3', async () => {
  for (const r of ['env', 'ctx', 'event', 'global', 'pf', 'ops', 'signal']) assert.equal((await run([['keep', root(r)]]))[0], 0, r);
  const [s, e] = await run([['get', root('window'), 'x']]);
  assert.equal(s, 3); assert.ok(e instanceof BadProgram); assert.match(e.message, /unknown root window/);
  assert.equal((await run([['get', root('toString'), 'x']]))[0], 3); // not an own root
});
await test('status 3: a slot out of range, an unknown op, a bad target or argument, a bad shape', async () => {
  for (const ops of [[['get', slot(0), 'x']], [['call', root('ops'), 'sleep', [slot(4)]]], [['jump', root('env')]], [['get', ['x', 1], 'a']], [['call', root('ops'), 'sleep', [['y', 1]]]], [['get', root('env')]], 'notalist', [['par', 'x']], [['record', [['k']]]]]) {
    assert.equal((await run(ops))[0], 3, JSON.stringify(ops));
    assert.equal((await run(ops, 'call'))[0], 3, JSON.stringify(ops));
  }
});
await test('status 1: a throw, a rejection, a thrown text (an Error with that message)', async () => {
  const [s, e] = await run([['call', root('ops'), 'boom', []]]);
  assert.equal(s, 1); assert.equal(e.name, 'RangeError');
  const [s2, e2] = await run([['call', root('ops'), 'reject', []]]);
  assert.equal(s2, 1); assert.equal(e2.name, 'TypeError');
  const [s3, e3] = await run([['call', root('ops'), 'throwText', []]], 'call');
  assert.equal(s3, 1); assert.equal(e3.message, 'text');
});
await test('OP1: await! awaits each thenable but start and keep; call! gives status 2 for a promise, not for start', async () => {
  const [, v] = await run([['call', root('ops'), 'sleep', [lit(5)]], ['array', [slot(0)]]]);
  assert.deepEqual(v, [5]);
  const [s1, pr] = await run([['start', root('ops'), 'sleep', [lit(5)]], ['keep', slot(0)]], 'call');
  assert.equal(s1, 0); assert.ok(pr.value instanceof Promise);
  const [s2, e2] = await run([['call', root('ops'), 'sleep', [lit(5)]]], 'call');
  assert.equal(s2, 2); assert.ok(e2 instanceof PromiseInCall);
  const [s3] = await run([['call', root('ops'), 'reject', []]], 'call');
  assert.equal(s3, 2); // a rejected promise is still a promise in call! (and no unhandled rejection)
});
await test('OP7: get and fields on null and undefined give undefined; call, set and new on them are status 1', async () => {
  for (const nil of [[['call', root('ops'), 'nil', []]], [['get', root('ops'), 'missing']]]) {
    for (const mode of ['await', 'call']) {
      assert.deepEqual(await run([...nil, ['get', slot(0), 'x']], mode), [0, undefined]);
      assert.deepEqual(await run([...nil, ['fields', slot(0), ['a', 'b']]], mode), [0, undefined]);
      for (const op of [['call', slot(0), 'f', []], ['set', slot(0), 'f', lit(1)], ['new', slot(0), 'F', []]]) {
        const [s, e] = await run([...nil, op], mode);
        assert.equal(s, 1, `${op[0]} ${mode}`); assert.equal(e.name, 'TypeError');
      }
    }
  }
});
await test('OP6: par runs branches at the same time (two 100 ms waits in about 100 ms), each with its own slots; [status, value] of each', async () => {
  const t0 = performance.now();
  const [s, v] = await run([['par', [[['call', root('ops'), 'sleep', [lit(100)]]], [['call', root('ops'), 'sleep', [lit(100)]], ['array', [slot(0), slot(0)]]], [['call', root('ops'), 'boom', []]], []]]]);
  const ms = performance.now() - t0;
  assert.equal(s, 0);
  assert.ok(ms < 180, `${ms} ms`);
  assert.deepEqual(v.slice(0, 2), [[0, 100], [0, [100, 100]]]);
  assert.equal(v[2][0], 1); assert.equal(v[2][1].name, 'RangeError');
  assert.deepEqual(v[3], [0, undefined]);
  assert.equal((await run([['par', [[['get', slot(3), 'x']], []]]]))[0], 3); // status 3 in a branch: the program
  assert.equal((await run([['par', [[], []]]], 'call'))[0], 2); // par in call!
});
await test('OP8: race gives [index, [status, value]] of the first to settle; the others see their abort; race [] is status 3', async () => {
  const seen = [];
  const watch = (ms, signal) => { signal.addEventListener('abort', () => seen.push(ms)); return sleep(ms, signal); };
  const c = ctxOf({ ops: { watch } });
  const t0 = performance.now();
  const [s, v] = await run([['race', [[['keep', root('signal')], ['call', root('ops'), 'watch', [lit(500), slot(0)]]], [['keep', root('signal')], ['call', root('ops'), 'watch', [lit(50), slot(0)]]]]]], 'await', c);
  const ms = performance.now() - t0;
  assert.equal(s, 0);
  assert.deepEqual(v, [1, [0, 50]]);
  assert.ok(ms < 200, `${ms} ms`);
  await sleep(1);
  assert.deepEqual(seen, [500]);
  const [s0, e0] = await run([['race', []]]);
  assert.equal(s0, 3); assert.match(e0.message, /no branch/);
  assert.equal((await run([['race', [[]]]], 'call'))[0], 2);
  // A branch that throws first wins with status 1.
  const [, v2] = await run([['race', [[['call', root('ops'), 'sleep', [lit(50)]]], [['call', root('ops'), 'reject', []]]]]]);
  assert.equal(v2[0], 1); assert.equal(v2[1][0], 1);
});
await test('writeResult: Kept is a Ref, a value that breaks J1 is status 1, the block grows in memory that moves, js_alloc 0 is status 4', async () => {
  // A fake instance: js_alloc grows the memory (a new buffer, the old views detach), res_free records the frees.
  const fake = () => {
    let mem = new WebAssembly.Memory({ initial: 1 });
    let top = 64;
    const freed = [];
    const x = {
      get memory() { return mem; },
      fail: Infinity,
      js_alloc(n) { if (--x.fail <= 0) return 0; const p = top; top += n + 8; while (top > mem.buffer.byteLength) mem.grow(1); return p; },
      res_free(p) { freed.push(p); },
      freed,
    };
    return x;
  };
  const read = (x, out, refs) => {
    const dv = new DataView(x.memory.buffer);
    return fromJs(new Uint8Array(x.memory.buffer, dv.getUint32(out, true), dv.getUint32(out + 4, true)), refs);
  };
  const refs = new Refs();
  class T {}
  const t = new T();
  let x = fake();
  assert.equal(writeResult(x, 8, 0, new Kept(7), refs), 0);
  assert.equal(read(x, 8, refs), 7);
  assert.equal(writeResult(x, 8, 0, [t, t], refs), 0);
  const back = read(x, 8, refs);
  assert.ok(back[0] === t && back[1] === t);
  const big = Array.from({ length: 5000 }, (_, i) => ({ id: i, name: 'n'.repeat(i % 50) }));
  assert.equal(writeResult(x, 8, 0, big, refs), 0);
  assert.deepEqual(read(x, 8, refs), big);
  assert.ok(x.freed.length > 3, `${x.freed.length} old blocks freed`);
  assert.equal(writeResult(x, 8, 0, 2n ** 64n, refs), 1);
  assert.equal(read(x, 8, refs).name, 'RangeError');
  assert.equal(writeResult(x, 8, 3, new BadProgram('m'), refs), 3);
  assert.equal(read(x, 8, refs).name, 'BadProgram');
  x = fake(); x.fail = 1;
  assert.equal(writeResult(x, 8, 0, 1, refs), 4);
  x = fake(); x.fail = 2;
  assert.equal(writeResult(x, 8, 0, big, refs), 4);
  assert.equal(x.freed.length, 1); // the first block
});
await test('pf: pack, packEach (the other fields stay), findById (undefined for an unknown id)', async () => {
  const c = ctxOf();
  const pf = c.roots.pf;
  const p = pf.pack([1], 10);
  assert.deepEqual([p.value, p.maxBytes], [[1], 10]);
  assert.equal(pf.pack(1).maxBytes, Infinity);
  const each = pf.packEach([{ results: [1], meta: 2 }, { results: [], meta: 3 }], 'results');
  assert.deepEqual(each.map((e) => [e.results.value, e.meta]), [[[1], 2], [[], 3]]);
  const msgs = [{ id: 'a' }, { id: 'b' }];
  assert.equal(pf.findById(msgs, 'b'), msgs[1]);
  assert.equal(pf.findById(msgs, 'z'), undefined);
  assert.throws(() => pf.findById('x', 'a'), TypeError);
});
await test('pf: the pin table (pinLimit, max age, counts)', async () => {
  let now = 0;
  const pins = makePins(2, () => now);
  pins.pin('a', 1); pins.pin('b', 2, 100);
  pins.pin('a', 3); // a pin of a name that is there is not a new entry
  assert.throws(() => pins.pin('c', 4), (e) => e instanceof RangeError && /pinLimit/.test(e.message));
  assert.equal(pins.pinned('a'), 3);
  now = 100;
  assert.equal(pins.pinned('b'), undefined);
  pins.unpin('a');
  assert.equal(pins.pinned('a'), undefined);
  assert.deepEqual(pins.stats, { pins: 3, unpins: 1, expired: 1 });
});
await test('pf: readUpTo reads to the limit; past it a TooLarge; spawn logs a throw and gives a promise that does not reject', async () => {
  const c = ctxOf();
  const stream = (n) => new ReadableStream({ start(ctl) { for (let i = 0; i < n; i++) ctl.enqueue(new Uint8Array(10).fill(i)); ctl.close(); } });
  const got = await c.roots.pf.readUpTo(stream(3), 30);
  assert.equal(got.length, 30); assert.equal(got[29], 2);
  await assert.rejects(c.roots.pf.readUpTo(stream(4), 30), (e) => e.name === 'TooLarge');
  logs.length = 0;
  const p = c.roots.pf.spawn([['call', root('ops'), 'reject', []]]);
  assert.equal(await p, undefined);
  assert.match(logs[0], /started program failed.*TypeError/);
  const w = c.roots.pf.writer();
  assert.ok(w.readable instanceof ReadableStream && w.writer instanceof WritableStreamDefaultWriter);
});

console.log(`${count - failed} of ${count} tests pass`);
process.exit(failed ? 1 : 0);
