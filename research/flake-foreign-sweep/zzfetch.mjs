// Probe: does a sweep by another request end the wait of a Fetch task (taskDeadlineMs 1000) at once?
// Use: cp research/flake-foreign-sweep/zzfetch.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ fetch sweep"; rm conformance/checks/zzfetch.mjs
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const checks = [
  ['ZZ fetch sweep: a sleep of 6 s, deadline of a wait 1 s, a sweep at 1.2 s', async (t) => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, taskDeadlineMs: 1000 }');
    if (entry === t.entry) throw new Error('no makeHandler options to change');
    const mf = t.start({ durableObjects: t.options?.durableObjects, handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const t0 = Date.now();
      const p = mf.dispatchFetch(`${base}/time/sleep?ms=6000`).then(async (r) => `${r.status} ${await r.text()} at ${Date.now() - t0} ms`);
      await sleep(1200);
      await (await mf.dispatchFetch(`${base}/time/now`)).text();
      const r = await p;
      if (!r.includes('503')) throw new Error(r);
      return r;
    } finally {
      await mf.dispose();
    }
  }],
];
