// Cost of the own-context deadline timer (js/index.js `watch`): the timers that the isolate sets for each request, and the time of a request.
// Use: cp research/flake-foreign-sweep/zzcost.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ cost"; rm conformance/checks/zzcost.mjs
// Run it on the commit before the change and on the change: the table of `research/flake-foreign-sweep/README.md` ("Cost").
// The entry counts the calls of `setTimeout` and `clearTimeout` of the isolate (`GET /__timers`).
const N = 400;
const routes = [
  ['Worker fetch (no object)', '/time/now'],
  ['object fetch! (Counter get)', '/objects/counter?name=cost&op=get'],
  ['object rpc (Counter ping)', '/objects/rpc/ping?name=cost'],
];
export const checks = [
  ['ZZ cost: timers and time for each request', async (t) => {
    const patch = (e) =>
      e
        .replace('const Handler = makeHandler(', 'let __set = 0, __clear = 0; const __st = globalThis.setTimeout, __ct = globalThis.clearTimeout;\nglobalThis.setTimeout = (...a) => (__set++, __st(...a)); globalThis.clearTimeout = (...a) => (__clear++, __ct(...a));\nconst Handler = makeHandler(')
        .replace("if (path === '/__mem')", "if (path === '/__timers') return Response.json({ set: __set, clear: __clear });\n    if (path === '/__mem')");
    const entry = patch(t.entry);
    if (entry === t.entry) throw new Error('no entry to patch');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const get = async (path) => (await mf.dispatchFetch(`${base}${path}`)).text();
      const timers = async () => JSON.parse(await get('/__timers'));
      const out = [];
      for (const [name, path] of routes) {
        for (let i = 0; i < 20; i++) await get(path); // warm up
        const a = await timers();
        const t0 = performance.now();
        for (let i = 0; i < N; i++) await get(path);
        const ms = performance.now() - t0;
        const b = await timers();
        out.push(`${name}: ${((b.set - a.set) / N).toFixed(2)} setTimeout, ${((b.clear - a.clear) / N).toFixed(2)} clearTimeout, ${((ms * 1000) / N).toFixed(0)} us`);
      }
      return out.join(' | ');
    } finally {
      await mf.dispose();
    }
  }],
];
