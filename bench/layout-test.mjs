// Removed 2026-10-16: the fallback for a module that is not stack-first (PLAN.md 1b). Such a module must fail loudly.
// node bench/layout-test.mjs bench/out/app.wasm
// The fixture bench/fixtures/data-first-10-09.wasm is bench/app_strloop.roc built with Roc nightly-2026-10-09-258ab27
// (data-first), by `ROC=<10-09 roc> OUT=<dir> bench/build.sh`.
// 1. The fixture is data-first (bench/check-layout.mjs says so, exit 1).
// 2. `makeHandler` accepts it at load. The first event throws an error that names the layout, the missing fallback
//    and bench/check-layout.mjs. Each later event throws too: the platform never serves from it.
// 3. `makeRunner` throws the same error.
// 4. A stack-first module (the argument) is served by the same code.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { makeHandler } from './cf-node.mjs';
import { makeRunner, check } from './core.js';
import { benchOps } from './ops.js';

const dataFirstFile = new URL('./fixtures/data-first-10-09.wasm', import.meta.url).pathname;
const dataFirst = new WebAssembly.Module(readFileSync(dataFirstFile));
const stackFirst = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const ops = benchOps(async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]));
const post = (text) => new Request('http://x/', { method: 'POST', body: text });
const wantError = (what, e) => {
  const m = String(e?.message ?? e);
  for (const re of [/not stack-first/, /no fallback/, /bench\/check-layout\.mjs/]) if (!re.test(m)) fail(`${what}: the message does not match ${re}: ${m}`);
};

// 1
const lay = spawnSync(process.execPath, [new URL('./check-layout.mjs', import.meta.url).pathname, dataFirstFile], { encoding: 'utf8' });
if (lay.status !== 1 || !/DATA-FIRST/.test(lay.stdout)) fail('the fixture is not data-first', lay.status, lay.stdout);

// 2
const H = makeHandler(dataFirst, { ops, isolateBytes: 2 ** 40 });
for (const round of [1, 2]) {
  let got = null;
  try {
    const r = await new H({}, {}).fetch(post('1 0 5'));
    got = `a response: ${r.status}`;
  } catch (e) {
    wantError(`event ${round}`, e);
    got = 'throw';
  }
  if (got !== 'throw') fail(`event ${round}: a data-first module was served (${got})`);
}

// 3
try {
  makeRunner(dataFirst, null, { isolateBytes: 2 ** 40 });
  fail('makeRunner: no throw');
} catch (e) {
  wantError('makeRunner', e);
}

// 4
{
  const G = makeHandler(stackFirst, { ops, isolateBytes: 2 ** 40 });
  const r = await new G({}, {}).fetch(post('7 0 5'));
  if (r.status !== 200 || !check('7', await r.text(), 5)) fail('a stack-first module was not served');
}
console.log(failed ? 'FAIL' : 'PASS: a data-first module throws at the first event, a stack-first one is served');
process.exit(failed ? 1 : 0);
