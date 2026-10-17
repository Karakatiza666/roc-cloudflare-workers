// PLAN.md step 8g in workerd: the wasm app of `app.roc` and `worker.js` in Miniflare (a library, local D1 with 200 rows).
//   node bench/8g/run-mf.mjs [app.wasm]    env: SECTIONS=cross,d1,d1real,parse,sha,parts,clock  RESUME=always|off  ROUNDS=9  TARGET_MS=100
// The client is this process (`dispatchFetch`): the request path cancels in (time of n = N less time of n = 0). JSON lines
// on stdout, then Markdown tables. MINIFLARE: the miniflare package (default: the one of the global wrangler).
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { makeMeasure, crossCases, d1Cases, parseCases, shaCases, sanity, table, fmt, ROWS } from './lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const runDir = join(root, '.cache/tmp', `8g-${process.pid}`);
mkdirSync(runDir, { recursive: true });
process.env.TMPDIR = runDir;
process.on('exit', () => rmSync(runDir, { recursive: true, force: true }));
const wasm = process.argv[2] ?? join(here, 'out/app.wasm');
const sections = (process.env.SECTIONS ?? 'cross,d1,d1real,parse,sha,parts,clock').split(',');
const resume = process.env.RESUME ?? 'always';
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const text = (p) => readFileSync(p, 'utf8');
const modules = [
  { type: 'ESModule', path: join(here, 'worker.js'), contents: text(join(here, 'worker.js')).replaceAll('__RESUME__', resume) },
  { type: 'ESModule', path: join(here, 'parts.js'), contents: text(join(here, 'parts.js')) },
  ...readdirSync(join(root, 'js')).filter((f) => f.endsWith('.js')).map((f) => ({ type: 'ESModule', path: join(here, 'js', f), contents: text(join(root, 'js', f)) })),
  { type: 'CompiledWasm', path: join(here, 'app.wasm'), contents: readFileSync(wasm) },
];
const mf = new Miniflare(convertV4MiniflareOptions({
  modules,
  modulesRoot: here,
  compatibilityDate: '2026-10-01',
  compatibilityFlags: ['enable_request_signal'],
  port: 0,
  d1Databases: ['DB'],
  cf: { colo: 'DFW' },
}));
try {
  await mf.ready;
  const get = (url) => mf.dispatchFetch(`http://localhost${url}`);
  const must = async (url) => {
    const r = await get(url);
    const body = await r.text();
    if (r.status !== 200) throw new Error(`${url}: ${r.status} ${body.slice(0, 300)}`);
    return body;
  };
  const rows = await must('/__setup?rows=200');
  if (rows !== '200') throw new Error(`setup: ${rows} rows`);
  const m = makeMeasure(get, { rounds: Number(process.env.ROUNDS ?? 9), targetMs: Number(process.env.TARGET_MS ?? 100) });
  const info = { runtime: 'workerd (Miniflare)', wasm, resumeCheck: resume, cpu: os.cpus()[0].model, cores: os.cpus().length, load: os.loadavg().map((v) => Math.round(v * 100) / 100), date: new Date().toISOString() };
  console.log(JSON.stringify({ info }));
  if (sections.includes('clock')) console.log(JSON.stringify({ clock: JSON.parse(await must('/__clock')) }));
  const fails = await sanity(m);
  if (fails.length) {
    console.log(JSON.stringify({ sanity: 'FAIL', fails }));
    process.exit(1);
  }
  console.log(JSON.stringify({ sanity: 'ok' }));
  const all = { cross: crossCases(), d1: d1Cases(true), d1real: d1Cases(false), parse: parseCases(), sha: shaCases() };
  const results = {};
  for (const g of ['cross', 'd1', 'd1real', 'parse', 'sha']) {
    if (!sections.includes(g)) continue;
    results[g] = [];
    // The real D1 costs about 2 ms a query and moves by 20 %: more time and more rounds for each case.
    const real = g === 'd1real';
    for (const c of all[g]) {
      const r = await m.measure(c.path, real ? { rounds: 15, targetMs: 600 } : {});
      results[g].push({ ...c, ...r });
      console.log(JSON.stringify({ group: g, name: c.name, N: r.N, us: r.us, min: r.min, max: r.max }));
    }
  }
  if (sections.includes('parts')) {
    results.parts = { rows: [], program: [] };
    for (const r of ROWS) results.parts.rows.push(JSON.parse(await must(`/__parts?rows=${r}`)));
    for (const k of [1, 4, 16]) results.parts.program.push(JSON.parse(await must(`/__parts?program=${k}`)));
    console.log(JSON.stringify({ parts: results.parts }));
  }
  console.log(JSON.stringify({ load_after: os.loadavg().map((v) => Math.round(v * 100) / 100) }));
  for (const g of Object.keys(results)) {
    if (g === 'parts') continue;
    console.log(`\n${g} (us per operation: median, min to max of ${process.env.ROUNDS ?? 9} rounds)\n`);
    console.log(table(results[g], [['case', (r) => r.name], ['N', (r) => r.N], ['us', fmt]]));
  }
} finally {
  await mf.dispose();
}
process.exit(0);
