// The Miniflare measure of research/chunk-fill/README.md: 110 MB of an outbound fetch body (`Http.open!` of the local
// server of conformance/run.mjs) through `chunk_with!` with fill 1 (one part for each call, as `chunk!` before) and the
// default `chunk!` (64 KiB). To run: copy to conformance/checks/zz-measure.mjs, then
// `node conformance/run.mjs bench/out/conformance.wasm "measure"`, then remove the copy.
export const options = {};
const N = 110 * 2 ** 20;
const one = async (t, q) => {
  let best;
  for (let i = 0; i < 3; i++) {
    const t0 = performance.now();
    const r = await t.get(`/body/open?url=${encodeURIComponent(`${t.server}/big?n=${N}`)}${q}&check=0`);
    const ms = performance.now() - t0;
    const m = /sizes=([\d,]*) .* bytes=(\d+) bad=(\d+)/.exec(r.body);
    const got = { ms: Math.round(ms), chunks: m[1].split(',').length, bytes: Number(m[2]), bad: Number(m[3]), awaits: r.awaits };
    if (!best || got.ms < best.ms) best = got;
  }
  return JSON.stringify(best);
};
export const checks = [
  ['measure chunk 110 MB fetch body', async (t) => `fill 1: ${await one(t, '&fill=1')}; default: ${await one(t, '')}; fill 256 KiB: ${await one(t, '&fill=262144')}`],
];
