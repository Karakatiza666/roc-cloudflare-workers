// `Ai` (MODULES.md 13): routes of conformance/AiRoutes.roc on the stub `STUB_AI` of conformance/bindings.js (Workers AI
// has no local form). The stub records `run(model, input, options)`, so a test sees what the module sent.
import { answer, eq, ok } from '../assert.mjs';
import { canon } from '../canon.mjs';

const calls = async (t) => JSON.parse((await t.get('/__stub_calls')).body);
const only = async (t) => {
  const c = await calls(t);
  eq(c.length, 1, 'the number of calls of the binding');
  eq(c[0].binding + '.' + c[0].method, 'AI.run', 'the call');
  return c[0].args;
};

export const checks = [
  ['ai run!: typed input and output, one wait', async (t) => {
    await t.get('/__stub_reset');
    const r = await t.get('/ai/run?model=@cf/m&prompt=hi');
    answer(r, 'Ok len=14 echo @cf/m: hi');
    eq(r.awaits, 1, 'js_await');
    // The input is the record of the app (CBOR: a plain object, a U64 is a number), and `run` has no options.
    eq(canon(await only(t)), canon(['@cf/m', { prompt: 'hi', max_tokens: 20 }, null]));
  }],
  ['ai run (Io twin)', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/ai/run_io?model=@cf/m&prompt=yo'), 'Ok len=14 echo @cf/m: yo');
    eq(canon(await only(t)), canon(['@cf/m', { prompt: 'yo', max_tokens: 20 }, null]));
  }],
  ['ai run_with!, run_with (Io twin): the gateway with all its fields, cache_ttl_ms in whole seconds, rounded up', async (t) => {
    for (const p of ['run_with', 'run_with_io']) {
      await t.get('/__stub_reset');
      answer(await t.get(`/ai/${p}?model=@cf/m&prompt=g&ttl=1500&max=5000`), 'Ok len=13 echo @cf/m: g');
      eq(canon(await only(t)), canon(['@cf/m', { prompt: 'g', max_tokens: 20 }, { gateway: { id: 'gw', skipCache: true, cacheTtl: 2, cacheKey: 'k1' } }]), p);
    }
  }],
  ['ai run_with!: a gateway with only its id sends only the id', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/ai/run_with_min?model=@cf/m&prompt=g'), 'Ok len=13 echo @cf/m: g');
    eq(canon((await only(t))[2]), canon({ gateway: { id: 'gw' } }));
  }],
  ['ai run_with!: max_bytes only sends no options to the binding', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/ai/run_with_max?model=@cf/m&prompt=g&max=5000'), 'Ok len=13 echo @cf/m: g');
    eq((await only(t))[2], null, 'options');
  }],
  ['ai run!: an output above 1 MiB is TooLarge, run_with! with max_bytes of 2 MiB gives it', async (t) => {
    answer(await t.get('/ai/run?model=@test/big&prompt=x'), 'TooLarge');
    answer(await t.get('/ai/run_with_max?model=@test/big&prompt=x&max=100'), 'TooLarge');
    answer(await t.get('/ai/run_with_max?model=@test/big&prompt=x&max=2000000'), `Ok len=1200000 ${'x'.repeat(40)}`);
  }],
  ['ai run!: a throw of the binding is AiErr', async (t) => answer(await t.get('/ai/run?model=@test/throw&prompt=x'), 'AiErr Error: no such model')],
  ['ai run!: an output that does not fit its type is BadData', async (t) => answer(await t.get('/ai/run_wrong?model=@cf/m&prompt=x'), 'BadData')],
  ['ai stream!, stream (Io twin): the stream of the model, with stream: true in the input', async (t) => {
    for (const p of ['stream', 'stream_io']) {
      await t.get('/__stub_reset');
      answer(await t.get(`/ai/${p}?model=@cf/m&prompt=s`), 'data: {"response":"a"}\n\ndata: {"response":"b"}\n\ndata: [DONE]\n\n');
      const a = await only(t);
      eq(canon(a), canon(['@cf/m', { prompt: 's', max_tokens: 20, stream: true }, null]), p);
    }
  }],
  ['ai stream!: a throw is AiErr', async (t) => answer(await t.get('/ai/stream?model=@test/throw&prompt=x'), 'AiErr Error: no such model')],
];
