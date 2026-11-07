// The shim option `stats` (research/alloc/README.md 6): the response header `x-roc-stats`. Node, no workerd.
// node bench/stats-test.mjs bench/out/app_prod.wasm
// 1. Option off (the default): no header, and no wrapper on the prototype.
// 2. Option on: the header is JSON with each field a number. A route that allocates more gives bigger counts: 500 items
//    against 5 items (allocs, bytes, livePeak), and `served` goes up by one for each request.
// 3. The peak of live bytes is not below the live bytes at the end, and it is the peak of the request (a window), not of the isolate.
// 4. A bad value of the option throws at `makeHandler`, and naming the option.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeHandler } from './cf-node.mjs';
import { benchOps } from './ops.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const io = async (kind, a, b) => (kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1]);
const ops = benchOps(io);
const post = (text) => new Request('http://x/', { method: 'POST', body: text });
const FIELDS = ['allocs', 'frees', 'reallocs', 'bytes', 'livePeak', 'liveEnd', 'mem', 'grows', 'ms', 'served', 'ageMs', 'inst'];

// 1
{
  const H = makeHandler(module, { ops, isolateBytes: 2 ** 40 });
  const res = await new H({}, {}).fetch(post('1 0 5'));
  if (res.headers.has('x-roc-stats')) fail('the header is there with the option off');
  if (Object.hasOwn(H.prototype, 'fetch') === false) fail('the class has no fetch');
}
// 2, 3
{
  const H = makeHandler(module, { ops, isolateBytes: 2 ** 40, stats: true });
  const h = new H({}, {});
  const get = async (text) => {
    const res = await h.fetch(post(text));
    await res.text();
    const raw = res.headers.get('x-roc-stats');
    if (!raw) {
      fail(`no header for ${text}`);
      return {};
    }
    return JSON.parse(raw);
  };
  const small = await get('1 0 5');
  const big = await get('2 0 500');
  const small2 = await get('3 0 5');
  console.log({ small, big, small2 });
  for (const s of [small, big, small2]) {
    for (const f of FIELDS) if (typeof s[f] !== 'number' || Number.isNaN(s[f])) fail(`field ${f} is not a number: ${s[f]}`);
    if (!(s.allocs > 0 && s.frees > 0 && s.bytes > 0 && s.mem > 0)) fail('a count is 0 for a route that allocates', s);
  }
  if (!(big.allocs > small.allocs * 1.5)) fail(`allocs: 500 items ${big.allocs}, 5 items ${small.allocs}`);
  if (!(big.bytes > small.bytes * 2)) fail(`bytes: 500 items ${big.bytes}, 5 items ${small.bytes}`);
  if (!(big.livePeak > small.livePeak * 1.5)) fail(`livePeak: 500 items ${big.livePeak}, 5 items ${small.livePeak}`);
  // The same route twice: the counts are the same (the allocator is deterministic here), not a total of the isolate.
  if (Math.abs(small2.allocs - small.allocs) > 2) fail(`allocs of one route change: ${small.allocs}, ${small2.allocs}`);
  if (big.served !== 2 || small2.served !== 3 || small.served !== 1) fail('served', small.served, big.served, small2.served);
  if (!(big.ageMs >= 0 && small2.ageMs >= big.ageMs)) fail('ageMs does not grow');
  if (!(big.livePeak >= big.liveEnd)) fail('livePeak below liveEnd');
  // The peak is of the request, not of the isolate: the small route after the big one has a small peak.
  if (!(small2.livePeak < big.livePeak * 0.8)) fail(`livePeak of the small route after the big one: ${small2.livePeak}, big ${big.livePeak}`);
}
// 4
for (const bad of [1, 'yes', null]) {
  try {
    makeHandler(module, { stats: bad });
    fail(`stats: ${JSON.stringify(bad)} does not throw`);
  } catch (e) {
    if (!/stats/.test(String(e))) fail(`the message does not name the option: ${e}`);
  }
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
