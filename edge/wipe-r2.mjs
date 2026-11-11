// PLAN.md 11c: deletes each object of the R2 buckets of the edge app (bindings BUCKET and TRACE), through `POST /__js`
// of edge/worker.js. The checks of conformance/checks/r2.mjs expect empty buckets (a fresh bucket of Miniflare), and a
// bucket with an incomplete multipart upload cannot be deleted (edge/deploy.sh delete), so a second run reuses it.
// It cannot abort incomplete multipart uploads (the binding cannot list them): the lifecycle rule of the bucket does that.
//   EDGE=https://rocplat-test-app.<sub>.workers.dev node edge/wipe-r2.mjs
const EDGE = process.env.EDGE.replace(/\/$/, '');
const js = async (b, chain) => {
  const j = await (await fetch(`${EDGE}/__js`, { method: 'POST', body: JSON.stringify({ b, chain }) })).json();
  if (j.err) throw new Error(`${b}: ${j.err.name}: ${j.err.message}`);
  return j.ok;
};
for (const b of ['BUCKET', 'TRACE']) {
  let n = 0;
  for (;;) {
    const page = await js(b, [['list', [{ limit: 1000 }]]]);
    const keys = page.objects.map((o) => o.key);
    if (keys.length === 0) break;
    await js(b, [['delete', [keys]]]);
    n += keys.length;
  }
  console.log(`${b}: deleted ${n} objects`);
}
