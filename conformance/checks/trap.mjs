// `on_trap` (MODULES.md 3, design note research/design-notes/trap-response.md) in Miniflare: bench/out/app_trap.wasm
// (bench/app_trap.roc) in a Miniflare of its own, with the shim of js/. The entry below sends `/box/<route>` to the
// object class Box and `/ep/<route>` to the named entry point Ep (a service binding to this Worker). The causes that
// need shim options (OOM, shed, deadline) are in bench/trap-test.mjs (Node).
// Env TRAP_WASM: another app_trap.wasm (a revert build).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ok } from '../assert.mjs';

export const options = {};

const self = Symbol.for('miniflare.kCurrentWorker');
const wasmPath = process.env.TRAP_WASM ?? fileURLToPath(new URL('../../bench/out/app_trap.wasm', import.meta.url));
const entry = `
import app from 'app.wasm';
import { makeHandler, objectClass, entrypointClass } from './js/index.js';
export const Box = objectClass('Box');
export const Ep = entrypointClass('Ep');
const H = makeHandler(app, { ops: { never: () => new Promise(() => {}) }, heapCheckWhenIdle: false });
export default class extends H {
  fetch(req) {
    const path = new URL(req.url).pathname;
    if (path.startsWith('/box/')) return this.env.BOX.get(this.env.BOX.idFromName('a')).fetch('http://x/' + path.slice(5));
    if (path.startsWith('/ep/')) return this.env.EP.fetch('http://x/' + path.slice(4));
    return super.fetch(req);
  }
}
`;

let shared;
const start = (t) => {
  shared ??= (async () => {
    const mods = [{ ...t.modules[0], contents: entry }, ...t.modules.slice(1).map((m) => (m.type === 'CompiledWasm' ? { ...m, contents: readFileSync(wasmPath) } : m))];
    const mf = t.startMiniflare({ modules: mods, durableObjects: { BOX: { className: 'Box', useSQLite: true } }, serviceBindings: { EP: { name: self, entrypoint: 'Ep' } }, handleStructuredLogs: () => {} });
    const base = (await mf.ready).href.replace(/\/$/, '');
    return async (path) => {
      const r = await mf.dispatchFetch(`${base}${path}`);
      return { status: r.status, headers: Object.fromEntries(r.headers), body: await r.text() };
    };
  })();
  return shared;
};

// The registry form of bench/app_trap.roc: problem+json, no-store, the title of the cause.
const problem = (r, status, title) => {
  let j = {};
  try {
    j = JSON.parse(r.body);
  } catch {}
  ok(r.status === status && r.headers['content-type'] === 'application/problem+json' && r.headers['cache-control'] === 'no-store' && j.title === title && j.status === status, `want ${status} ${title}, got ${JSON.stringify(r)}`);
  return `${r.status} ${j.title}`;
};

export const checks = [
  ['trap: crash gives the entry crashed, and a second crash the full body again (TR4)', async (t) => {
    const get = await start(t);
    const a = await get('/crash');
    const b = await get('/crash');
    problem(a, 500, 'Crashed');
    ok(b.body === a.body, `the second body: ${JSON.stringify(b)}`);
    ok(!('retry-after' in a.headers), 'retry-after on a crash');
    return problem(b, 500, 'Crashed');
  }],
  ['trap: Err gives the entry failed', async (t) => problem(await (await start(t))('/err'), 502, 'Failed')],
  ['trap: a good request is not changed', async (t) => {
    const r = await (await start(t))('/ok');
    ok(r.status === 200 && r.body === 'ok', JSON.stringify(r));
  }],
  ['trap: the fetch of an object class uses the table (TR3)', async (t) => problem(await (await start(t))('/box/crash'), 500, 'Crashed')],
  ['trap: the fetch of a named entry point uses the table (TR3)', async (t) => {
    const get = await start(t);
    problem(await get('/ep/crash'), 500, 'Crashed');
    return problem(await get('/ep/err'), 502, 'Failed');
  }],
  ['trap: a crash after Response.after does not change the sent response', async (t) => {
    const r = await (await start(t))('/after');
    ok(r.status === 200 && r.body === 'early', JSON.stringify(r));
  }],
];
