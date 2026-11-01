// workerd: GET /run?v=<variant wasm name>&chunk=<bytes>: one stream of the input (data module `input.zst`)
// through the probe wasm, in a new instance (the wasm is compiled once). The client times the request.
import { instantiate, stream } from './core.mjs';
import input from 'input.zst';
const mods = { WASMS };
let owner = 1;
export default {
  async fetch(req) {
    const u = new URL(req.url);
    const m = mods[u.searchParams.get('v')];
    if (!m) return new Response('no such variant', { status: 404 });
    const w = await instantiate(m);
    const z = new Uint8Array(input);
    const r = stream(w, z, Number(u.searchParams.get('chunk') ?? 65536), owner++);
    return Response.json({ ...r, wasmMem: w.x.memory.buffer.byteLength });
  },
};
