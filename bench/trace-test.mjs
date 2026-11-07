// The shim option `trace` and the trace host (research/alloc/README.md 6). Node, no workerd.
// node bench/trace-test.mjs bench/out/app_trace.wasm bench/out/app_prod.wasm research/alloc/out/replay_port.wasm
//   app_trace.wasm: bench/app_prod.roc on the trace platform (research/alloc/trace-platform.sh).
//   replay_port.wasm: the replay module of the platform allocator (research/alloc/replay/build.sh port).
// 1. A trace of known routes (5 items and 500 items, 40 requests, 8 at once) has the ops alloc, free, realloc, task end and sum
//    (no adopt: the blocks of JS are not in the trace), and a 500 items request
//    has more records than a 5 items one.
// 2. The trace replays on the allocator of the platform (`replay.zig`, sum mode 2) with no trap and no sum difference,
//    and at the end no block is live.
// 3. `trace: true` (no function) gives the same records through `takeTrace()`.
// 4. The option needs the trace host, and the trace host needs the option (errors at load).
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeHandler } from './cf-node.mjs';
import { benchOps } from './ops.js';

const load = (f) => new WebAssembly.Module(readFileSync(f));
const traceMod = load(process.argv[2]);
const prodMod = load(process.argv[3]);
const replayMod = load(process.argv[4]);
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const io = async (kind, a, b) => {
  await new Promise((r) => setTimeout(r, 1));
  return kind === 1 ? 'f:' + new URL(b).searchParams.get('id') : 'd:' + a.split(' ')[1];
};
const post = (text) => new Request('http://x/', { method: 'POST', body: text });
const join = (chunks) => {
  const out = new Uint32Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) (out.set(c, at), (at += c.length));
  return out;
};
const ops = (rec) => {
  const c = [0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < rec.length; i += 4) c[rec[i] & 0xff]++;
  return c;
};

// Replay as research/alloc/scripts/replay.mjs does, in 65,536-record parts. Gives { bad, live, trapped }.
function replay(rec) {
  const x = new WebAssembly.Instance(replayMod, {}).exports;
  x.set_sum(2);
  const rb = x.rec_buf();
  const CH = 1 << 16;
  try {
    for (let i = 0; i < rec.length; i += CH * 4) {
      const part = rec.subarray(i, Math.min(rec.length, i + CH * 4));
      new Uint32Array(x.memory.buffer, rb, part.length).set(part);
      x.run(part.length / 4);
    }
  } catch (e) {
    return { trapped: String(e) };
  }
  return { bad: x.sum_mismatch(), live: x.live_bytes() };
}

const chunks = [];
const H = makeHandler(traceMod, { ops: benchOps(io), isolateBytes: 2 ** 40, trace: (c) => chunks.push(c) });
const h = new H({}, {});
// 1: one request alone for each size, then 40 requests with 8 at once.
const alone = async (text) => {
  const n = chunks.length;
  await (await h.fetch(post(text))).text();
  return join(chunks.slice(n));
};
const t5 = await alone('1 0 5');
const t500 = await alone('2 0 500');
console.log('records: 5 items', t5.length / 4, ', 500 items', t500.length / 4);
for (let b = 0; b < 5; b++) {
  const ids = Array.from({ length: 8 }, (_, i) => 10 + b * 8 + i);
  await Promise.all(ids.map(async (id) => (await h.fetch(post(`${id} 0 ${id % 2 ? 5 : 500}`))).text()));
}
const all = join(chunks);
const c = ops(all);
console.log({ records: all.length / 4, alloc: c[1], free: c[2], realloc: c[3], taskEnd: c[4], sum: c[5], adopt: c[6], stats: H.traceStats });
for (const [name, k] of [['alloc', 1], ['free', 2], ['realloc', 3], ['task end', 4], ['sum', 5]]) if (c[k] === 0) fail(`no ${name} record`);
if (!(t500.length > t5.length * 1.5)) fail(`500 items has ${t500.length / 4} records, 5 items ${t5.length / 4}`);
// 2
const r = replay(all);
console.log('replay', r);
if (r.trapped) fail(`the replay trapped: ${r.trapped}`);
else {
  // `sum_mismatch` counts a sum that differs in its low 16 bits. Its high part counts a wait with no call of the task before the
  // next wait of the same task (the replay finds a resume by the next call): the real app has such waits, so only the low part counts.
  if ((r.bad & 0xffff) !== 0) fail(`replay: ${r.bad & 0xffff} sums differ`);
  if (r.live !== 0) fail(`replay: ${r.live} bytes live at the end`);
}
// 3: with `trace: true` (no function) the same two requests give the same records through `takeTrace()`.
{
  const H2 = makeHandler(traceMod, { ops: benchOps(io), isolateBytes: 2 ** 40, trace: true });
  const h2 = new H2({}, {});
  await (await h2.fetch(post('1 0 5'))).text();
  await (await h2.fetch(post('2 0 500'))).text();
  const got = H2.takeTrace();
  const want = join([t5, t500]);
  if (got.length !== want.length || got.some((v, i) => v !== want[i])) fail(`takeTrace: ${got.length / 4} records, the function got ${want.length / 4}`);
  if (H2.takeTrace().length !== 0) fail('takeTrace: records left after a take');
}
// 4
try {
  makeHandler(prodMod, { trace: true });
  fail('trace on the release host does not throw');
} catch (e) {
  if (!/trace host/.test(String(e))) fail(`message: ${e}`);
}
try {
  makeHandler(traceMod, {});
  fail('the trace host without the option does not throw');
} catch (e) {
  if (!/trace host/.test(String(e))) fail(`message: ${e}`);
}
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
