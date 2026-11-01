// Probe P3 of research/design-notes/test-helper.md 10 (step S1): the shim pin table can be cleared from a JS route when the
// task table is empty, and the next `Memo` read loads again. Before the probe the runner had no handle on the table
// (only `stats.pins`); the probe needs `runner.pins` (js/runner.js) and `pins.clear()` (js/helpers.js).
//   node research/test-helper/probes/p3.mjs <helper.wasm>
import { startApp } from '../../../js/test.mjs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const app = await startApp({ dir: join(root, 'test-helper/app'), shim: '../../js', wasm: resolve(process.argv[2]), d1: { DB: ['CREATE TABLE items (v TEXT)'] } });
const ctl = async (p) => (await app.mf.dispatchFetch(`http://localhost/__cfw_test/${app.token}/${p}`)).json();
const memo = async () => (await app.fetch('/memo')).text();
const a = await memo();
const b = await memo();
console.log('P3 two reads, one load:', a === b, '| tasks and pins:', JSON.stringify(await ctl('tasks')));
console.log('P3 reset:', JSON.stringify(await ctl('reset')), '| tasks and pins:', JSON.stringify(await ctl('tasks')));
const c = await memo();
console.log('P3 the read after the clear loads again:', c !== a);
await app.close();
