// Probe (research/chunk-fill/README.md): the parts of a body stream in workerd, and how a fill to a target size can
// see that the next part is not ready. GET /probe?src=req|fetch&how=none|each|micro|timer&target=N&url=U
const NOT = Symbol('not ready');
const hop = (k) => { let p = Promise.resolve(NOT); for (let i = 0; i < k; i++) p = p.then((v) => v); return p; };
const ready = {
  none: (p) => p,
  micro: (p) => Promise.race([p, hop(4)]),
  timer: (p) => new Promise((res, rej) => { const t = setTimeout(() => res(NOT), 0); p.then((v) => (clearTimeout(t), res(v)), rej); }),
};
async function fill(st, target, how) {
  let parts = [], n = 0;
  while (n < target && !st.done) {
    const p = st.pending ?? st.reader.read();
    st.pending = p;
    const got = n === 0 ? await p : await ready[how](p);
    if (got === NOT) { st.notReady++; break; }
    st.pending = null;
    st.reads++;
    if (got.done) { st.done = true; break; }
    parts.push(got.value.byteLength); n += got.value.byteLength;
    if (how === 'each') break;
  }
  return n ? n : undefined;
}
export default {
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/ping') return new Response('pong');
    const how = u.searchParams.get('how') ?? 'each';
    const target = Number(u.searchParams.get('target') ?? 65536);
    const body = u.searchParams.get('src') === 'fetch' ? (await fetch(u.searchParams.get('url'))).body : req.body;
    const st = { reader: body.getReader(), pending: null, done: false, reads: 0, notReady: 0 };
    let fills = 0, total = 0, min = Infinity, max = 0;
    for (;;) {
      const n = await fill(st, how === 'each' ? Infinity : target, how);
      if (n === undefined) break;
      fills++; total += n; min = Math.min(min, n); max = Math.max(max, n);
    }
    return Response.json({ how, target, fills, reads: st.reads, notReady: st.notReady, total, avg: Math.round(total / fills), min, max });
  },
};
