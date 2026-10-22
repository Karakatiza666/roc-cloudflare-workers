// The deadline of a task needs no other request (API.md 10.2, PLAN.md 8h "Exact deadlines"): the task has a timer in its own
// context (`watch`, js/index.js) that sweeps at the deadline. Each check has a wait that is much longer than the deadline and
// sends NO other request, so only that timer can cancel the task. The cancel ends the task at about the deadline plus 50 ms,
// not at the end of the wait. The bounds are wide for a slow machine: the deadline is 500 ms, the wait 5000 ms, the bound 2500 ms.
// The Init case is in checks/objects.mjs. The repros: research/flake-foreign-sweep/.
import { ok } from '../assert.mjs';

export const options = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const WAIT = 5000;
const BOUND = 2500;

// One Miniflare for the four checks, started at the first one (run.mjs disposes it at its end). `taskDeadlineMs` is the limit of
// one wait of a Fetch, an ObjectFetch and an Rpc task, `wallMs` the limit of the whole Alarm task.
let shared;
const start = (t) => {
  shared ??= (async () => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, taskDeadlineMs: 500, wallMs: 500 }');
    ok(entry !== t.entry, 'no makeHandler options to change');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    const base = (await mf.ready).href.replace(/\/$/, '');
    return { mf, base, get: async (path) => (await mf.dispatchFetch(`${base}${path}`)).text() };
  })();
  return shared;
};

// A request whose task waits `WAIT` ms: it must end before `BOUND` ms. `route` is the path with the wait in it.
const cut = (what, route) => [`deadline ${what}: a wait of ${WAIT} ms with a deadline of 500 ms ends near the deadline, with no other request`, async (t) => {
  const { get } = await start(t);
  const name = what.replace(/\W+/g, '');
  await get(`/objects/counter/id?name=${name}`); // the object is started
  const t0 = Date.now();
  const body = await get(route(name));
  const ms = Date.now() - t0;
  ok(ms < BOUND, `the deadline did not cut the wait: ${ms} ms (${body.slice(0, 80)})`);
  return `${ms} ms`;
}];

export const checks = [
  cut('Worker Fetch', () => `/time/sleep?ms=${WAIT}`),
  // ObjectFetch and Rpc: a call from JS (`/__object_wait`, conformance/worker.js). A Roc route of the Worker would also have a
  // deadline timer, and its sweep would cancel the object task: the check would not show the timer of the object task.
  cut('ObjectFetch', (n) => `/__object_wait?kind=fetch&name=${n}&ms=${WAIT}`),
  cut('Rpc', (n) => `/__object_wait?kind=rpc&name=${n}&ms=${WAIT}`),
  // Alarm: `/alarm_nap` sets an alarm that runs about 10 ms later (Miniflare: 2 to 3 s later) and sleeps. The check polls
  // `/__stats` for the start of the alarm task (`tasks` above 0), then for its end.
  ['deadline Alarm: a wait of 5000 ms with a limit of 500 ms for the task ends near the limit, with no other request', async (t) => {
    const { get } = await start(t);
    const tasks = async () => JSON.parse(await get('/__stats')).tasks;
    await get('/objects/counter/id?name=alarm'); // the object is started
    await get(`/objects/counter/alarm_nap?name=alarm&ms=${WAIT}`);
    const t0 = Date.now();
    while ((await tasks()) === 0) {
      ok(Date.now() - t0 < 10000, 'the alarm did not start');
      await sleep(5);
    }
    const started = Date.now();
    while ((await tasks()) > 0) {
      ok(Date.now() - started < 10000, 'the alarm task did not end');
      await sleep(5);
    }
    const ms = Date.now() - started;
    ok(ms < BOUND, `the deadline did not cut the wait: the alarm task ended ${ms} ms after its start`);
    return `the alarm task ended ${ms} ms after its start`;
  }],
  // The timer of a task is cleared at the task end: a timer that stays sweeps each 100 ms for ever (`timers` of `/__stats`,
  // conformance/worker.js: the timers set and not yet fired or cleared). A new Miniflare, so the timers of other checks do not count.
  ['deadline timers: the timer of a task is cleared at its end (Worker Fetch, ObjectFetch, Rpc)', async (t) => {
    const mf = t.start({ handleStructuredLogs: () => {} });
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const get = async (path) => (await mf.dispatchFetch(`${base}${path}`)).text();
      await get('/time/now');
      await get('/objects/counter/id?name=tm');
      await get('/objects/rpc/ping?name=tm');
      await get('/objects/counter/sleep?name=tm&ms=20');
      await sleep(400); // several ticks of a timer that stayed (each 100 ms)
      const st = JSON.parse(await get('/__stats'));
      ok(st.timers === 0, `${st.timers} timers still set after the tasks ended`);
      return `timers ${st.timers}, tasks ${st.tasks}`;
    } finally {
      await mf.dispose();
    }
  }],
];
