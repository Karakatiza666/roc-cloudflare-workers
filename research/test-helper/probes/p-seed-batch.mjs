// Probe (0.0.6, Talon registry note 5): the time of app.reset() with a seed of 1 table and 100 inserts.
// Run: node research/test-helper/probes/p-seed-batch.mjs <helper.wasm>
import { startApp } from '../../../js/test.mjs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../../..');
const seed = ['CREATE TABLE items (v TEXT);' + Array.from({ length: 100 }, (_, i) => ` INSERT INTO items (v) VALUES ('${i}');`).join('')];
const app = await startApp({ dir: join(root, 'test-helper/app'), shim: '../../js', wasm: resolve(process.argv[2]), d1: { DB: seed } });
const times = [];
for (let i = 0; i < 6; i++) {
  const t = performance.now();
  await app.reset();
  times.push(performance.now() - t);
}
await app.close();
times.shift();
console.log(`reset, mean of 5: ${(times.reduce((a, b) => a + b) / times.length).toFixed(0)} ms`);
