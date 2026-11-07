// CFW_TEST_TRACE (js/test.mjs): an app on the trace host runs under startApp (Miniflare), and `close()` writes its allocator
// trace to the file of the env var. The trace replays on the platform allocator with no trap and no sum difference.
//   node test-helper/trace-env-test.mjs <app_trace.wasm> <replay_port.wasm>
//   app_trace.wasm: bench/app_prod.roc on the trace platform (bench/build.sh). replay_port.wasm: research/alloc/replay/build.sh port.
// Checks: 1. with CFW_TEST_TRACE, the file has records of the ops alloc, free, realloc, task end and sum; 2. the records of
// more requests are more; 3. the trace replays (sum mode 2) with 0 sums that differ and no live block at the end;
// 4. app.takeTrace() gives the records, and they are then not in the file. Exit 1 on a failure.
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startApp } from '../js/test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const traceWasm = resolve(process.argv[2] ?? join(here, '../bench/out/app_trace.wasm'));
const replayMod = new WebAssembly.Module(readFileSync(resolve(process.argv[3] ?? join(here, '../research/alloc/out/replay_port.wasm'))));
let failed = false;
const check = (ok, name, why = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ok ? '' : `: ${why}`}`);
  if (!ok) failed = true;
};
const dir = mkdtempSync(join(tmpdir(), 'cfw-trace-env-'));
// The ops of bench/app_prod.roc (`effect!`): they run in workerd, from the options module of the app dir.
writeFileSync(join(dir, 'worker.options.js'), "export default { ops: { fetch: async (m, url) => 'f:' + new URL(url).searchParams.get('id'), db: async (q) => 'd:' + q.split(' ')[1] } };\n");
const ops = (rec) => {
  const c = [0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < rec.length; i += 4) c[rec[i] & 0xff]++;
  return c;
};
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
  return { bad: x.sum_mismatch() & 0xffff, live: x.live_bytes() };
}
const run = async (file, n, take = false) => {
  process.env.CFW_TEST_TRACE = file;
  const app = await startApp({ dir, shim: join(here, '../js'), wasm: traceWasm });
  try {
    for (let i = 0; i < n; i++) {
      const res = await app.fetch('/', { method: 'POST', body: `${i + 1} 0 ${i % 2 ? 5 : 300}` });
      await res.text();
      if (res.status !== 200) throw new Error(`status ${res.status}`);
    }
    return take ? await app.takeTrace() : null;
  } finally {
    await app.close();
    delete process.env.CFW_TEST_TRACE;
  }
};
const read = (f) => (existsSync(f) ? new Uint32Array(readFileSync(f).buffer.slice(0)) : new Uint32Array(0));
try {
  const f2 = join(dir, 'two.bin');
  const f8 = join(dir, 'eight.bin');
  await run(f2, 2);
  await run(f8, 8);
  const t2 = read(f2);
  const t8 = read(f8);
  const c = ops(t8);
  console.log({ records2: t2.length / 4, records8: t8.length / 4, alloc: c[1], free: c[2], realloc: c[3], taskEnd: c[4], sum: c[5] });
  check(t8.length > 0, 'CFW_TEST_TRACE: close() writes the trace file', 'no records');
  check(c[1] > 0 && c[2] > 0 && c[3] > 0 && c[4] === 8 && c[5] > 0, 'the trace has alloc, free, realloc, sum and one task end per request', JSON.stringify(c));
  check(t8.length > t2.length, 'more requests give more records', `${t2.length / 4} >= ${t8.length / 4}`);
  const r = replay(t8);
  check(!r.trapped && r.bad === 0 && r.live === 0, 'the trace replays on the platform allocator (sum mode 2)', JSON.stringify(r));
  const ft = join(dir, 'take.bin');
  const taken = await run(ft, 2, true);
  check(taken.length > 0 && read(ft).length === 0, 'takeTrace() gives the records; the file gets only the rest', `taken ${taken.length / 4}, file ${read(ft).length / 4}`);
} catch (e) {
  check(false, 'run', e.stack ?? String(e));
} finally {
  rmSync(dir, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
