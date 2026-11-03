// Probe (0.0.6 notes, Talon registry): does the result of Fetcher.queue() (app.queue) give the delay of each retry?
// Run: node research/test-helper/probes/p-retry-delay.mjs
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require = createRequire(execSync('npm root -g').toString().trim() + '/wrangler/');
const { Miniflare, convertV4MiniflareOptions } = require('miniflare');
const script = `export default {
  async fetch() { return new Response('ok'); },
  async queue(batch) {
    const [a, b, c] = batch.messages;
    a.retry({ delaySeconds: 30 });
    b.retry();
    c.ack();
    if (batch.messages.length > 3) batch.retryAll({ delaySeconds: 7 });
  },
};`;
const v4 = { modules: true, script, compatibilityDate: '2026-10-01', queueConsumers: { q: {} } };
const mf = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(v4) : v4);
const w = await mf.getWorker();
const msg = (id) => ({ id, timestamp: new Date(), body: id, attempts: 1 });
console.log('3 messages:', JSON.stringify(await w.queue('q', [msg('a'), msg('b'), msg('c')])));
console.log('4 messages (retryAll 7 s):', JSON.stringify(await w.queue('q', [msg('a'), msg('b'), msg('c'), msg('d')])));
await mf.dispose();
