// Does an R2 put of a FixedLengthStream end when the stream has its length, with no close? (PLAN.md 8c RO1: the
// route of RC13 with the public `Body.Writer.write` twin.) Cases: write all bytes and no close; write then close.
//   node research/writer-twin/fixed.mjs   (Miniflare of the global wrangler)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
const timeout = (ms) => new Promise((r) => setTimeout(() => r('timeout'), ms));
export default { async fetch(req, env) {
  const out = {};
  for (const close of [false, true]) {
    const ts = new TransformStream();
    const w = ts.writable.getWriter();
    const fl = new FixedLengthStream(11);
    const put = env.B.put('k' + close, ts.readable.pipeThrough(fl)).then((o) => 'put ' + o.size, (e) => 'put err ' + e.message);
    const write = w.write(new TextEncoder().encode('hello world')).then(() => 'written', (e) => 'write err ' + e.message);
    const both = Promise.all([put, write]).then((x) => x.join(', '));
    if (close) write.then(() => w.close());
    out['close=' + close] = await Promise.race([both, timeout(1500)]);
  }
  return Response.json(out);
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', r2Buckets: ['B'] }));
console.log(await (await mf.dispatchFetch('http://x/')).text());
await mf.dispose();
