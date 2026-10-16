// `Analytics` (MODULES.md 13): routes of conformance/AnalyticsRoutes.roc. `STATS` is the local Analytics Engine dataset
// (it keeps nothing), `STUB_STATS` is the stub of conformance/bindings.js that records the data point.
import { answer, eq } from '../assert.mjs';
import { canon } from '../canon.mjs';

export const options = { analyticsEngineDatasets: { STATS: { dataset: 'conformance' } } };

const calls = async (t) => JSON.parse((await t.get('/__stub_calls')).body);

export const checks = [
  ['analytics write!: the local binding, and a binding that is not in the config', async (t) => {
    const r = await t.get('/analytics/write?name=STATS');
    answer(r, 'Ok');
    // `writeDataPoint` gives no promise: one call!, no wait.
    eq(r.awaits, 0, 'js_await');
    eq(r.calls, 1, 'js_call');
    answer(await t.get('/analytics/write?name=NOPE'), 'AnalyticsErr TypeError');
  }],
  ['analytics write!: blobs, doubles and indexes reach the binding', async (t) => {
    await t.get('/__stub_reset');
    answer(await t.get('/analytics/write?name=STUB_STATS'), 'Ok');
    answer(await t.get('/analytics/write_empty?name=STUB_STATS'), 'Ok');
    eq(canon(await calls(t)), canon([
      { binding: 'STUB_STATS', method: 'writeDataPoint', args: [{ blobs: ['a', 'b'], doubles: [1.5, 2], indexes: ['i'] }] },
      { binding: 'STUB_STATS', method: 'writeDataPoint', args: [{ blobs: [], doubles: [], indexes: [] }] },
    ]), 'the recorded data points');
  }],
];
