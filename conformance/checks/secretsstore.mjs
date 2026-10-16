// `SecretsStore` (MODULES.md 13): routes of conformance/SecretsStoreRoutes.roc, on the local Secrets Store of Miniflare.
// `KEY` gets its value from the admin API of the test, `NOKEY` has none.
import { answer, eq } from '../assert.mjs';

export const options = {
  secretsStoreSecrets: {
    KEY: { store_id: 'conformance', secret_name: 'key' },
    NOKEY: { store_id: 'conformance', secret_name: 'nokey' },
  },
};

let made = false;
const setup = async (t) => {
  if (made) return;
  await (await t.mf.getSecretsStoreSecretAPI('KEY'))().create('s3cr3t');
  made = true;
};

export const checks = [
  ['secretsstore get!: a Secret that shows only by reveal, one wait', async (t) => {
    await setup(t);
    const r = await t.get('/secretsstore/get?name=KEY');
    answer(r, 'Ok inspect=Secret(...) reveal=s3cr3t');
    eq(r.awaits, 1, 'js_await');
  }],
  ['secretsstore get (Io twin)', async (t) => {
    await setup(t);
    answer(await t.get('/secretsstore/get_io?name=KEY'), 'Ok inspect=Secret(...) reveal=s3cr3t');
  }],
  ['secretsstore get!: a secret that does not exist is SecretsStoreErr', async (t) => {
    await setup(t);
    answer(await t.get('/secretsstore/get?name=NOKEY'), 'SecretsStoreErr Error: Secret "nokey" not found');
    answer(await t.get('/secretsstore/get?name=NO_SUCH_BINDING'), 'SecretsStoreErr TypeError: Cannot read properties of undefined (reading \'get\')');
  }],
];
