// `Env` and `Secret` (MODULES.md 10): routes of conformance/EnvRoutes.roc. `bindings` are the vars of the Wrangler
// config: text, a JSON object, JSON text, and a secret (a text var).
import { answer } from '../assert.mjs';

export const options = {
  bindings: { TEXT_VAR: 'hello', JSON_VAR: { name: 'a', n: 3 }, JSON_TEXT: '{"name":"b","n":4}', SECRET_VAR: 'hunter2' },
};

export const checks = [
  ['env var!', async (t) => {
    answer(await t.get('/env/var?name=TEXT_VAR'), 'Ok("hello")');
    answer(await t.get('/env/var?name=NOPE'), 'Err(Infra(MissingEnv("NOPE")))');
    answer(await t.get('/env/var?name=JSON_VAR'), 'Err(Infra(MissingEnv("JSON_VAR")))');
  }],
  ['env json!', async (t) => {
    answer(await t.get('/env/json?name=JSON_VAR'), 'Ok a 3');
    answer(await t.get('/env/json?name=JSON_TEXT'), 'Ok b 4');
    answer(await t.get('/env/json?name=NOPE'), 'MissingEnv NOPE');
    answer(await t.get('/env/json?name=TEXT_VAR'), 'BadData');
  }],
  ['env secret!', async (t) => {
    answer(await t.get('/env/secret?name=SECRET_VAR'), 'inspect=Secret(...) reveal=hunter2');
    answer(await t.get('/env/secret?name=NOPE'), 'Infra(MissingEnv("NOPE"))');
  }],
  ['secret from_str, to_inspect, reveal', async (t) => answer(await t.get('/env/from_str?name=pw'), 'inspect={ token: Secret(...) } reveal=pw')],
];
