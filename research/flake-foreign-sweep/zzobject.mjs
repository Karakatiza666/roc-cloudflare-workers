// Repro: an object task that is past its deadline. Two cases for each kind (ObjectFetch, Rpc, Alarm): a request of another context sweeps (the
// sweep cancels the task from another context), and 'none': no other request comes (only the timer of the task can cancel it).
// Use: cp research/flake-foreign-sweep/zzobject.mjs conformance/checks/ && node conformance/run.mjs bench/out/conformance.wasm "ZZ object"; rm conformance/checks/zzobject.mjs
// Counter `/sleep?ms=` and its Rpc method `nap` (conformance/ObjectRoutes.roc, RpcMethods.roc) wait before their reply. With `taskDeadlineMs: 500` the deadline of its wait is 500 ms.
// A request of the Worker at 510 ms to 540 ms sweeps first (js/runner.js `run`): a sweep from another context. The Worker request for the
// object answers when the object task ends. Expected: about 560 ms (the timer of the task: deadline + 50 ms).
// Seen before the fix: 'foreign sweep': 520 to 550 ms (the wake of the sweep works for these kinds, not for Init); 'no other request': about
// 2500 ms (the end of the sleep: nothing sweeps, the task is cancelled only at its next wait).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const checks = [];
// kind: the route of the object task. ObjectFetch: Counter `/sleep`. Rpc: the Rpc method `nap` of Counter (`RpcMethods.nap`).
const kinds = { ObjectFetch: (n) => `/objects/counter/sleep?name=${n}&ms=2500`, Rpc: (n) => `/objects/rpc/nap?name=${n}&ms=2500` };
for (const [kind, route] of Object.entries(kinds)) for (const d of [510, 520, 530, 540, 'none']) {
  checks.push([`ZZ object ${d === 'none' ? 'no other request' : 'foreign sweep'} ${kind} ${d}`, async (t) => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, taskDeadlineMs: 500 }');
    if (entry === t.entry) throw new Error('no makeHandler options to change');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const get = async (path) => (await mf.dispatchFetch(`${base}${path}`)).text();
      await get(`/objects/counter/id?name=zz${d}`); // the object is started
      const t0 = Date.now();
      const p = get(route(`zz${d}`)).then((body) => ({ body, ms: Date.now() - t0 }));
      if (d !== 'none') {
        await sleep(d);
        await get('/objects/counter/id?name=zzother');
      }
      const r = await p;
      if (r.ms > 1200) throw new Error(`the cancel at the sweep did not end the wait: ${r.ms} ms (${r.body})`);
      return `${r.ms} ms: ${r.body.slice(0, 60)}`;
    } finally {
      await mf.dispose();
    }
  }]);
}

// Kind Alarm: Counter `/alarm_nap?ms=` sets an alarm that runs about 10 ms later (Miniflare: 2 to 3 s later) and sleeps. `wallMs: 500` is its
// whole-task limit. The check polls `/__stats` for the start of the alarm task (`tasks` above 0), sends the request of another context `d` ms
// after it, and polls for the end. Expected: about 550 ms after the start (500 ms + 50 ms). Before the fix: 'foreign sweep' about 520 to 540 ms, 'no other request' the end of the sleep (2500 ms).
for (const d of [515, 525, 535, 'none']) {
  checks.push([`ZZ object ${d === 'none' ? 'no other request' : 'foreign sweep'} Alarm ${d}`, async (t) => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, wallMs: 500 }');
    if (entry === t.entry) throw new Error('no makeHandler options to change');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const get = async (path) => (await mf.dispatchFetch(`${base}${path}`)).text();
      const tasks = async () => JSON.parse(await get('/__stats')).tasks;
      await get(`/objects/counter/id?name=za${d}`); // the object is started
      await get(`/objects/counter/alarm_nap?name=za${d}&ms=2500`);
      const t0 = Date.now();
      while ((await tasks()) === 0) {
        if (Date.now() - t0 > 8000) throw new Error('the alarm did not start');
        await sleep(5);
      }
      const started = Date.now();
      if (d !== 'none') {
        await sleep(d);
        await get('/objects/counter/id?name=zzother');
      }
      while ((await tasks()) > 0) {
        if (Date.now() - started > 8000) throw new Error('the alarm task did not end');
        await sleep(5);
      }
      const ms = Date.now() - started;
      if (ms > 1300) throw new Error(`the cancel at the sweep did not end the wait: the alarm task ended ${ms} ms after its start`);
      return `the alarm task ended ${ms} ms after its start`;
    } finally {
      await mf.dispose();
    }
  }]);
}
