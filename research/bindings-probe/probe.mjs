// Local facts of the bindings of PLAN.md 8f part 4 (Miniflare 5): what each binding gives in a plain worker.
//   node research/bindings-probe/probe.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const script = `
import { WorkflowEntrypoint } from 'cloudflare:workers';
export class Flow extends WorkflowEntrypoint {
  async run(event, step) {
    const x = await step.do('one', async () => ({ got: event.payload, id: event.instanceId }));
    return x;
  }
}
const show = (v) => { try { return JSON.stringify(v); } catch (e) { return 'unserializable: ' + e.message; } };
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const out = {};
    try {
      if (url.pathname === '/version') out.v = env.V;
      if (url.pathname === '/analytics') out.a = [typeof env.STATS.writeDataPoint, env.STATS.writeDataPoint({ blobs: ['a'], doubles: [1], indexes: ['i'] })];
      if (url.pathname === '/hyper') out.h = { cs: env.PG.connectionString, host: env.PG.host, port: env.PG.port, user: env.PG.user, password: env.PG.password, database: env.PG.database, keys: Object.keys(env.PG) };
      if (url.pathname === '/secret') out.s = await env.KEY.get();
      if (url.pathname === '/secret_missing') out.s = await env.NOKEY.get();
      if (url.pathname === '/assets') { const r = await env.ASSETS.fetch(new Request('http://x/hello.txt')); out.a = [r.status, await r.text(), [...r.headers]]; }
      if (url.pathname === '/assets404') { const r = await env.ASSETS.fetch(new Request('http://x/nope.txt')); out.a = [r.status, await r.text()]; }
      if (url.pathname === '/wf') {
        const inst = await env.FLOW.create({ id: 'i1', params: { a: 1 } });
        out.id = inst.id;
        await new Promise((r) => setTimeout(r, 500));
        const i2 = await env.FLOW.get('i1');
        out.status = await i2.status();
        out.keys = Object.keys(inst);
        out.proto = Object.getOwnPropertyNames(Object.getPrototypeOf(inst));
      }
      if (url.pathname === '/wf_missing') { const i = await env.FLOW.get('nope'); out.id = i.id; out.status = await i.status(); }
      if (url.pathname === '/wf_dup') { await env.FLOW.create({ id: 'dup', params: 1 }); await env.FLOW.create({ id: 'dup', params: 1 }); }
      if (url.pathname === '/wf_ctl') {
        const inst = await env.FLOW.create({ id: 'c1', params: { b: 2 } });
        await inst.pause(); out.paused = await inst.status();
        await inst.resume(); out.resumed = await inst.status();
        await inst.sendEvent({ type: 'ping', payload: { x: 1 } });
        await inst.terminate(); out.term = await inst.status();
      }
    } catch (e) { out.err = [e.name, e.message]; }
    return new Response(show(out));
  },
};`;

const mf = new Miniflare(convertV4MiniflareOptions({
  modules: [{ type: 'ESModule', path: join(here, 'w.mjs'), contents: script }],
  compatibilityDate: '2026-10-01',
  port: 0,
  versionMetadata: 'V',
  analyticsEngineDatasets: { STATS: { dataset: 'stats' } },
  hyperdrives: { PG: 'postgres://user:secret@localhost:5432/mydb' },
  secretsStoreSecrets: { KEY: { store_id: 'st', secret_name: 'key' }, NOKEY: { store_id: 'st', secret_name: 'nokey' } },
  assets: { directory: join(here, 'assets'), binding: 'ASSETS', run_worker_first: true, routerConfig: { has_user_worker: true } },
  workflows: { FLOW: { name: 'flow', className: 'Flow' } },
}));
await mf.ready;
try {
  const api = (await mf.getSecretsStoreSecretAPI('KEY'))();
  await api.create('s3cr3t');
} catch (e) { console.log('secret api:', e.message); }
for (const p of ['version', 'analytics', 'hyper', 'secret', 'secret_missing', 'assets', 'assets404', 'wf', 'wf_missing', 'wf_dup', 'wf_ctl']) {
  const r = await mf.dispatchFetch(`http://localhost/${p}`);
  console.log(p, r.status, (await r.text()).slice(0, 700));
}
await mf.dispose();
