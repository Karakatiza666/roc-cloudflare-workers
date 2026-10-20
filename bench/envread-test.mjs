// N7 (MODULES.md 3): the dev-mode warning of a binding that the app reads and `Worker.new bindings` does not declare (Node).
// node bench/envread-test.mjs [dir with app_envread.wasm and app_envread_none.wasm]    (default: bench/out)
//   app_envread.wasm       bindings: [KV]. The app reads KV, OTHER and OTHER2 (bindings), TEXT_VAR, SECRET_VAR, JSON_VAR (vars).
//   app_envread_none.wasm  the same app with no `bindings`: the check is off.
// The warning is one log line for each name in one isolate (one `makeHandler`).
import { readFileSync } from 'node:fs';
import { makeHandler } from './cf-node.mjs';

const dir = process.argv[2] ?? 'bench/out';
const load = (f) => new WebAssembly.Module(readFileSync(`${dir}/${f}`));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const check = (name, cond, why) => (cond ? pass(name) : fail(`${name}: ${why}`));

// A real binding is a class instance, not a plain object.
class Ns {
  async get() {
    return null;
  }
  async put() {}
  async getWithMetadata() {
    return {};
  }
  async list() {
    return {};
  }
  async delete() {}
}
const env = () => ({ KV: new Ns(), OTHER: new Ns(), OTHER2: new Ns(), TEXT_VAR: 'hello', SECRET_VAR: 'hunter2', JSON_VAR: { n: 3 } });

// A new isolate (handler) that logs into `lines`, and `get(path)`: the status and the text of the answer.
function isolate(wasm) {
  const lines = [];
  const H = makeHandler(load(wasm), { log: (t) => lines.push(String(t)) });
  const e = env();
  const get = async (path) => {
    const r = await new H({ waitUntil() {} }, e).fetch(new Request(`http://x/${path}`));
    return `${r.status} ${await r.text()}`;
  };
  const warnings = () => lines.filter((l) => l.includes('reads the binding'));
  return { get, warnings, lines };
}
const words = (w) => w.map((l) => /env\.(\w+)/.exec(l)?.[1]).join(',');

// 1. An undeclared binding read 3 times: one warning, with the name, the cause and the fix.
{
  const a = isolate('app_envread.wasm');
  for (let i = 0; i < 3; i++) await a.get('other');
  const w = a.warnings();
  check('1a undeclared OTHER read 3 times: exactly one warning', w.length === 1, `${w.length} warnings: ${w.join(' | ')}`);
  check('1b the warning names the binding, Worker.new bindings and declare()', w[0]?.includes('the app reads the binding env.OTHER, but Worker.new bindings does not declare it') && w[0].includes('declare()'), w[0]);
  // 2. One warning for each name: OTHER2 warns once, OTHER does not warn again.
  await a.get('other2');
  await a.get('other2');
  await a.get('other');
  check('2 one warning for each name (OTHER, OTHER2)', words(a.warnings()) === 'OTHER,OTHER2', words(a.warnings()));
}
// 3. A declared binding, a text var, a secret and a plain JSON var: no warning (also with another binding undeclared).
{
  const a = isolate('app_envread.wasm');
  const got = [await a.get('kv'), await a.get('kv'), await a.get('var'), await a.get('secret'), await a.get('json')];
  check('3a declared KV, a var, a secret and a JSON var give the answers', got[0].startsWith('200 ') && got[2] === '200 Ok("hello")' && got[3] === '200 Ok("hunter2")' && got[4] === '200 Ok({ n: 3 })', got.join(' | '));
  check('3b ...and no warning', a.warnings().length === 0, a.warnings().join(' | '));
}
// 4. A new isolate warns again: the set of names is for one isolate.
{
  const a = isolate('app_envread.wasm');
  const b = isolate('app_envread.wasm');
  await a.get('other');
  await b.get('other');
  check('4 each isolate warns once', a.warnings().length === 1 && b.warnings().length === 1, `${a.warnings().length} and ${b.warnings().length}`);
}
// 5. An app that declares no binding: no warning for any read (the check is off).
{
  const a = isolate('app_envread_none.wasm');
  const got = [await a.get('kv'), await a.get('other'), await a.get('other2'), await a.get('other'), await a.get('var'), await a.get('secret'), await a.get('json')];
  check('5a no bindings declared: the app serves', got.every((g) => g.startsWith('200 ')), got.join(' | '));
  check('5b ...and no warning', a.warnings().length === 0, a.warnings().join(' | '));
}
process.exit(failed ? 1 : 0);
