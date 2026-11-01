// The shim option `wrapEnv` (TH11, research/design-notes/test-helper.md 10 S2): `worker.js` gives a request with the header
// `x-count-d1` a counted `DB`. A route of D1Routes.roc with one batch is one call; with no header the count stays 0.
// The tables come from the setup of checks/d1.mjs (an earlier file).
import { eq } from '../assert.mjs';

const calls = async (t) => Number((await t.get('/__d1_calls')).body);

export const checks = [
  ['wrapEnv: a wrapped D1 counts the calls of a route (1 batch of 2 statements is 1 call)', async (t) => {
    await calls(t);
    const r = await t.get(`/d1/batch?sql=${encodeURIComponent('SELECT 1;SELECT 2')}`, { headers: { 'x-count-d1': '1' } });
    eq(r.status, 200, 'status');
    eq(await calls(t), 1, 'calls with the header');
    await t.get(`/d1/batch?sql=${encodeURIComponent('SELECT 1;SELECT 2')}`);
    eq(await calls(t), 0, 'calls with no header');
    return r.body;
  }],
];
