// Local facts of Workflows with a waiting instance (PLAN.md 8f part 4): states after pause, resume, terminate, sendEvent.
//   node research/bindings-probe/wait.mjs
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const script = `
import { WorkflowEntrypoint } from 'cloudflare:workers';
export class Waiter extends WorkflowEntrypoint {
  async run(event, step) {
    const got = await step.waitForEvent('wait for go', { type: 'go', timeout: '1 minute' });
    return { started: event.payload, got: got.payload };
  }
}
export default {
  async fetch(request, env) {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const st = async (i) => (await i.status()).status;
    const out = [];
    try {
      const a = await env.W.create({ id: 'a', params: { n: 1 } });
      await sleep(300); out.push(['created', await st(a)]);
      await a.pause(); await sleep(300); out.push(['paused', await st(a)]);
      await a.resume(); await sleep(300); out.push(['resumed', await st(a)]);
      await a.sendEvent({ type: 'go', payload: { x: 1 } }); await sleep(500);
      const s = await a.status(); out.push(['sent', s.status, JSON.stringify(s.output)]);
      const b = await env.W.create({ id: 'b', params: 2 });
      await sleep(300); await b.terminate(); await sleep(300); out.push(['terminated', await st(b)]);
      const c = await env.W.create({ id: 'c', params: 3 });
      await sleep(300); await c.sendEvent({ type: 'other', payload: 1 }); await sleep(300); out.push(['wrong type', await st(c)]);
    } catch (e) { out.push(['err', e.name, e.message]); }
    return new Response(JSON.stringify(out));
  },
};`;
const mf = new Miniflare(convertV4MiniflareOptions({
  modules: [{ type: 'ESModule', path: join(here, 'w.mjs'), contents: script }],
  compatibilityDate: '2026-10-01',
  port: 0,
  workflows: { W: { name: 'waiter', className: 'Waiter' } },
}));
await mf.ready;
const r = await mf.dispatchFetch('http://localhost/');
console.log(r.status, await r.text());
await mf.dispose();
