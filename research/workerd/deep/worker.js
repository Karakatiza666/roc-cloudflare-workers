import { makeRunner } from './core.js';
import deep from './app_deep.wasm';
import v from './app_v.wasm';
const mods = { deep, v };
let runners = {};
export default {
  async fetch(request) {
    const u = new URL(request.url);
    const name = u.searchParams.get('m') ?? 'deep';
    if (u.searchParams.get('fresh') === '1' || !runners[name]) runners[name] = makeRunner(mods[name], 'b', async () => 'x', { noFallback: true });
    const r = runners[name];
    const x = r.x;
    const res = await r.run(u.searchParams.get('q'));
    const sp = x.sp_at_abort() >>> 0, mem = x.memory.buffer.byteLength;
    return Response.json({ q: u.searchParams.get('q'), kind: res.body !== undefined ? 'body' : res.trap.slice(0, 30), sp, where: res.body !== undefined ? '' : sp < x.canary_base() ? 'below CANARY_BASE' : sp >= mem ? 'above memory' : 'in stack', retired: r.stats.retired });
  },
};
