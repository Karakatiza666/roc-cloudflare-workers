// PLAN.md step 8g: the worker of the measure app in workerd (Miniflare, `run-mf.mjs`, or Wrangler, `run-edge.mjs`). The same
// app as `run-node.mjs`, with the real D1 binding `DB`. `__RESUME__` is replaced by the runner (`always` or `off`).
//   GET /__parts?rows=<n> or ?program=<k>   the parts of one crossing (`parts.js`), timed here with `performance.now()`
//   GET /__clock                            the resolution of the clocks in a busy loop
//   GET /__setup?rows=<n>                   (edge) makes the table `releases` with n rows, once
import app from 'app.wasm';
import { makeHandler } from './js/index.js';
import * as values from './js/values.js';
import * as bridge from './js/bridge.js';
import * as program from './js/program.js';
import { makeParts, rowArrays, COLUMNS } from './parts.js';

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
const Handler = makeHandler(app, { ops, heapCheckWhenIdle: false, heapCheckEvery: 0, resumeCheck: '__RESUME__' });

// The D1 binding of `run-node.mjs` in JS: the same 200 rows, made once. `?fake=1` uses it in place of the real `DB`, so a
// case measures the platform (the shim, the host, Roc) and not the SQLite of the local D1.
const arrays = rowArrays(200);
const objects = arrays.map((r) => Object.fromEntries(COLUMNS.map((c, i) => [c, r[i]])));
const fakeDB = {
  prepare: () => ({
    bind: (rows) => ({
      all: async () => ({ results: objects.slice(0, Number(rows)), meta: { changes: 0, last_row_id: 0, rows_read: Number(rows), rows_written: 0, duration: 0.1 }, success: true }),
      raw: async (o) => (o?.columnNames ? [COLUMNS, ...arrays.slice(0, Number(rows))] : arrays.slice(0, Number(rows))),
    }),
  }),
};

export default class extends Handler {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.searchParams.get('fake') === '1') this.env = { ...this.env, DB: fakeDB };
    if (url.pathname === '/__parts') {
      const p = makeParts({ x: Handler.runner.x, values, bridge, program, now: () => performance.now() });
      const rows = url.searchParams.get('rows');
      const k = url.searchParams.get('program');
      return Response.json(rows ? p.rows(Number(rows)) : p.program(Number(k)));
    }
    if (url.pathname === '/__clock') {
      const step = (f) => {
        const t0 = f();
        let t = t0;
        let n = 0;
        while (t === t0 && n < 5e7) {
          t = f();
          n++;
        }
        return { delta: t - t0, spins: n };
      };
      const sample = (f) => Array.from({ length: 5 }, () => step(f));
      const t0 = performance.now();
      let x = 0;
      for (let i = 0; i < 3e7; i++) x += i;
      return Response.json({ perf: sample(() => performance.now()), date: sample(() => Date.now()), busy_ms: performance.now() - t0, x });
    }
    if (url.pathname === '/__setup') {
      const rows = Number(url.searchParams.get('rows') ?? 200);
      const db = this.env.DB;
      await db.exec('DROP TABLE IF EXISTS releases');
      await db.exec('CREATE TABLE releases (grp TEXT, version TEXT, hash TEXT, url TEXT, published_at INTEGER, log_index INTEGER, yanked INTEGER, provenance TEXT)');
      const stmt = db.prepare(`INSERT INTO releases (${COLUMNS.join(', ')}) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
      await db.batch(rowArrays(rows).map((r) => stmt.bind(...r)));
      const n = await db.prepare('SELECT COUNT(*) AS n FROM releases').first('n');
      return new Response(String(n));
    }
    return super.fetch(request);
  }
}
