// The child of test-helper/helper-tmpdir.sh: two apps, one request, then it waits for a signal.
//   node test-helper/tmpdir-child.mjs <helper.wasm>
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startApp } from '../js/test.mjs';

const dir = join(dirname(fileURLToPath(import.meta.url)), 'app');
const wasm = resolve(process.argv[2]);
const a = await startApp({ dir, shim: '../../js', wasm, d1: { DB: ['CREATE TABLE items (v TEXT)'] } });
await startApp({ dir, shim: '../../js', wasm });
await a.fetch('/now');
console.log('ready');
setInterval(() => {}, 1000);
