// PLAN.md step 8g in Node: the cost of `track_live` and of the optimize mode of the host in the Zig tree decode.
//   node bench/8g/run-variants.mjs [variant ...]    (default: default tl_off ot_off fast fast_tl_off; build them with `bench/8g/build.sh`)
// Each variant is one wasm (`out/app-<variant>.wasm`) with its own host. For 5 reps in rotating order, each variant gives:
//   decode200 / decode20   `cbor_check` of the tree bytes of 200 / 20 rows (Zig decode and free, no task): us
//   rows200, all200        whole requests of `D1.rows!` and `D1.all!` (fake D1, Node): us per call
// The median over the reps and the spread. `ot_off` differs from `tl_off` by no byte (`cmp`), so it is the same host.
import { readFileSync } from 'node:fs';
import os from 'node:os';
import { makeHandler } from '../cf-node.mjs';
import * as values from '../../js/values.js';
import * as bridge from '../../js/bridge.js';
import * as program from '../../js/program.js';
import { makeMeasure, median, round } from './lib.mjs';
import { makeParts, rowArrays, rowObjects, COLUMNS } from './parts.js';

const variants = process.argv.slice(2).length ? process.argv.slice(2) : ['default', 'tl_off', 'ot_off', 'fast', 'fast_tl_off'];
const reps = Number(process.env.REPS ?? 5);
const arrays = rowArrays(200);
const objects = rowObjects(200);
const fakeDB = {
  prepare: () => ({
    bind: (rows) => ({
      all: async () => ({ results: objects.slice(0, Number(rows)), meta: { changes: 0, last_row_id: 0, rows_read: Number(rows), rows_written: 0, duration: 0.1 }, success: true }),
      raw: async (o) => (o?.columnNames ? [COLUMNS, ...arrays.slice(0, Number(rows))] : arrays.slice(0, Number(rows))),
    }),
  }),
};
const ctx = { waitUntil() {} };
const state = {};
for (const v of variants) {
  const module = new WebAssembly.Module(readFileSync(new URL(`./out/app-${v}.wasm`, import.meta.url)));
  const Handler = makeHandler(module, { ops: { lib: {} }, heapCheckWhenIdle: false, heapCheckEvery: 0 });
  const get = (url) => new Handler(ctx, { DB: fakeDB }).fetch(new Request(`http://x${url}`));
  const m = makeMeasure(get, { rounds: 5, targetMs: 100 });
  const p = makeParts({ x: Handler.runner.x, values, bridge, program, now: () => performance.now() });
  state[v] = { m, p, got: { decode200: [], decode20: [], rows200: [], all200: [] } };
}
console.log(JSON.stringify({ info: { runtime: `node ${process.version}`, cpu: os.cpus()[0].model, load: os.loadavg(), variants, reps } }));
for (let rep = 0; rep < reps; rep++) {
  const order = variants.map((_, i) => variants[(i + rep) % variants.length]);
  for (const v of order) {
    const s = state[v];
    s.got.decode200.push(s.p.rows(200).zig_decode_tree.us);
    s.got.decode20.push(s.p.rows(20).zig_decode_tree.us);
    s.got.rows200.push((await s.m.measure('/d1/rows?rows=200&fake=1')).us);
    s.got.all200.push((await s.m.measure('/d1/all?rows=200&fake=1')).us);
  }
}
const lines = ['| variant | decode 200 rows (us) | decode 20 rows (us) | D1.rows! 200 (us) | D1.all! 200 (us) |', '| --- | --- | --- | --- | --- |'];
const cell = (xs) => `${round(median(xs), 2)} (${round(Math.min(...xs), 2)} to ${round(Math.max(...xs), 2)})`;
for (const v of variants) lines.push(`| ${v} | ${cell(state[v].got.decode200)} | ${cell(state[v].got.decode20)} | ${cell(state[v].got.rows200)} | ${cell(state[v].got.all200)} |`);
console.log(lines.join('\n'));
console.log(JSON.stringify({ load_after: os.loadavg() }));
process.exit(0);
