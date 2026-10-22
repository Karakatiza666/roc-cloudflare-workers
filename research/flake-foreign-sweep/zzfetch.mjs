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
  // The same with no other request: nothing sweeps. Before the timer of each task (js/index.js `watch`, also for a Worker task) it ended when the sleep ended (2579 ms); now at about 560 ms.
  ['ZZ fetch no other request: a sleep of 2.5 s, deadline of a wait 0.5 s', async (t) => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, taskDeadlineMs: 500 }');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const t0 = Date.now();
      const r = await (await mf.dispatchFetch(`${base}/time/sleep?ms=2500`)).text();
      const ms = Date.now() - t0;
      if (ms > 1200) throw new Error(`the deadline did not cut the wait: ${r.slice(0, 40)} at ${ms} ms`);
      return `${r.slice(0, 40)} at ${ms} ms`;
    } finally {
      await mf.dispose();
    }
  }],
];
