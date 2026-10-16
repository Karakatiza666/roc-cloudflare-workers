// The shim option `ops` (PLAN.md 8a O4): a value that is an object, reached from Roc with `Get` and `Call`.
import { answer } from '../assert.mjs';

export const options = {};

export const checks = [
  ['shim: ops with an object value', async (t) => answer(await t.get('/shim/ops'), 'Ok(Int(42))')],
];
