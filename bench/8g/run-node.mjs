// PLAN.md step 8g in Node: the wasm app of `app.roc` behind `makeHandler` (the platform shim), a fake D1 binding.
//   node bench/8g/run-node.mjs [app.wasm]            env: SECTIONS=cross,d1,parse,sha,parts  RESUME=always|off  ROUNDS=9  TARGET_MS=100
// The fake D1 (`prepare().bind(rows).all()` and `raw()`) gives the same 200 rows as `research/api-probe/cbor/`, objects made
// once. Real D1 (Miniflare, `run-mf.mjs`) also makes its own objects. JSON lines on stdout, then Markdown tables.
import { readFileSync } from 'node:fs';
import os from 'node:os';
import { makeHandler } from '../cf-node.mjs';
import * as values from '../../js/values.js';
import * as bridge from '../../js/bridge.js';
import * as program from '../../js/program.js';
import { makeMeasure, crossCases, d1Cases, parseCases, shaCases, sanity, table, fmt, ROWS } from './lib.mjs';
import { makeParts, rowArrays, rowObjects, COLUMNS } from './parts.js';

const wasm = process.argv[2] ?? 'bench/8g/out/app.wasm';
const sections = (process.env.SECTIONS ?? 'cross,d1,parse,sha,parts').split(',');
const resume = process.env.RESUME ?? 'always';
const module = new WebAssembly.Module(readFileSync(wasm));

// The JS functions of the app (`ops` root): a cached buffer of `size` bytes, and the length of a buffer.
const bufs = new Map();
const ops = {
  lib: {
    buf: (size) => {
      let b = bufs.get(size);
      if (!b) bufs.set(size, (b = new Uint8Array(size).fill(7)));
      return b;
    },
    len: (b) => b.length,
  },
};

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

const Handler = makeHandler(module, { ops, heapCheckWhenIdle: false, heapCheckEvery: 0, resumeCheck: resume });
const env = { DB: fakeDB };
const ctx = { waitUntil() {} };
const get = (url) => new Handler(ctx, env).fetch(new Request(`http://x${url}`));
const m = makeMeasure(get, { rounds: Number(process.env.ROUNDS ?? 9), targetMs: Number(process.env.TARGET_MS ?? 100) });

const info = { runtime: `node ${process.version}`, wasm, resumeCheck: resume, cpu: os.cpus()[0].model, cores: os.cpus().length, load: os.loadavg().map((v) => Math.round(v * 100) / 100), date: new Date().toISOString() };
console.log(JSON.stringify({ info }));
const fails = await sanity(m);
if (fails.length) {
  console.log(JSON.stringify({ sanity: 'FAIL', fails }));
  process.exit(1);
}
console.log(JSON.stringify({ sanity: 'ok' }));

const all = { cross: crossCases(), d1: d1Cases(true), parse: parseCases(), sha: shaCases() };
const results = {};
for (const g of ['cross', 'd1', 'parse', 'sha']) {
  if (!sections.includes(g)) continue;
  results[g] = [];
  for (const c of all[g]) {
    const r = await m.measure(c.path);
    results[g].push({ ...c, ...r });
    console.log(JSON.stringify({ group: g, name: c.name, N: r.N, us: r.us, min: r.min, max: r.max }));
  }
}
if (sections.includes('parts')) {
  const x = Handler.runner.x;
  const p = makeParts({ x, values, bridge, program, now: () => performance.now() });
  results.parts = { rows: ROWS.map((r) => p.rows(r)), program: [0, 1, 4, 16].map((k) => (k ? p.program(k) : null)).filter(Boolean) };
  console.log(JSON.stringify({ parts: results.parts }));
}
console.log(JSON.stringify({ info, load_after: os.loadavg().map((v) => Math.round(v * 100) / 100) }));
for (const g of Object.keys(results)) {
  if (g === 'parts') continue;
  console.log(`\n${g} (us per operation: median, min to max of ${process.env.ROUNDS ?? 9} rounds)\n`);
  console.log(table(results[g], [['case', (r) => r.name], ['N', (r) => r.N], ['us', fmt]]));
}
process.exit(0);
