// The one clock of the shim (the `makeHandler` option `now`): conformance/worker.js gives `now = Date.now() + clockSkew`, and
// `GET /__clock?skew=<ms>` sets the skew (a JS route: no Roc task, so no sweep). `Time.now_ms!`, the `max_age_ms` of `Memo`,
// the task deadlines, `Io.timeout_at` and `Object.Self.set_alarm_in!` must all follow it. Timers stay real.
// The checks use their own Miniflare (a deadline of 3000 ms for one wait), so the skew does not touch the other checks.
import { eq, ok } from '../assert.mjs';

export const options = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const DEADLINE = 3000;
const memo = /^Ok kid=k1 big=1152921504606846976 made=([0-9a-f-]{36})$/;

let shared;
const start = (t) => {
  shared ??= (async () => {
    const entry = t.entry.replace('initMs: 1000 }', `initMs: 1000, taskDeadlineMs: ${DEADLINE} }`);
    ok(entry !== t.entry, 'no makeHandler options to change');
    const mf = t.start({ handleStructuredLogs: () => {} }, entry);
    const base = (await mf.ready).href.replace(/\/$/, '');
    const get = async (path) => {
      const r = await mf.dispatchFetch(`${base}${path}`);
      return { status: r.status, body: await r.text() };
    };
    const skew = async (ms) => eq((await get(`/__clock?skew=${ms}`)).body, String(ms), 'the skew');
    return { get, skew };
  })();
  return shared;
};

// Each check sets the skew back to 0 at its end, also on a failure.
const check = (name, fn) => [`clock ${name}`, async (t) => {
  const s = await start(t);
  try {
    return await fn(s);
  } finally {
    await s.skew(0);
  }
}];

export const checks = [
  check('Time.now_ms!: the time of the shim option now, not Date.now()', async ({ get, skew }) => {
    await skew(1e9);
    const r = await get('/time/now');
    const want = Date.now() + 1e9;
    ok(r.status === 200 && Math.abs(Number(r.body) - want) < 5000, `got ${r.status} ${r.body}, want a time near ${want}`);
    return r.body;
  }),
  check('Memo max_age_ms: the value stays until the clock of the shim moves past the age, then load! runs again', async ({ get, skew }) => {
    const id = async () => {
      const r = await get('/memo/clock');
      const m = memo.exec(r.body);
      ok(r.status === 200 && m, `got ${r.status} ${r.body}`);
      return m[1];
    };
    const a = await id();
    await skew(59_000);
    eq(await id(), a, 'the id 59 s later on the clock (age 60 s): a new id, so it expired too early');
    await skew(61_000);
    const c = await id();
    ok(c !== a, 'the same id 61 s later on the clock (age 60 s): it did not expire');
    return `${a} until 59 s, ${c} at 61 s`;
  }),
  // A deadline 100 ms after `Time.now_ms!` on a clock 1e9 ms ahead: TimedOut after about 100 ms (a real timer), not the end
  // of the sleep of 3 s (Ok) that a wait on `Date.now()` gives.
  check('Io.timeout_at: the deadline is on the clock of the shim', async ({ get, skew }) => {
    await skew(1e9);
    const t0 = Date.now();
    const r = await get('/time/timeout_at_wait');
    const ms = Date.now() - t0;
    eq(r.body, 'Err(Infra(TimedOut))', 'the answer');
    ok(ms < 1500, `${ms} ms: want about 100 ms`);
    return `${ms} ms`;
  }),
  // A task waits 5000 ms with a wait deadline of 3000 ms. After 300 ms the clock moves 10 s forward, and a second request
  // sweeps the task table (js/runner.js `runOwned`): the wait is past its deadline on the clock, so the sweep cancels it.
  check('deadline: the sweep reads the clock of the shim (a wait past the deadline on the clock is cancelled at once)', async ({ get, skew }) => {
    const t0 = Date.now();
    const slow = get('/time/sleep?ms=5000');
    await sleep(300);
    await skew(10_000);
    await get('/time/now');
    const r = await slow;
    const ms = Date.now() - t0;
    ok(r.body !== 'slept', `the wait was not cancelled: ${r.status} ${r.body}`);
    ok(ms < DEADLINE - 1000, `the task ended after ${ms} ms: the sweep did not use the clock of the shim (real deadline ${DEADLINE} ms)`);
    return `${r.status} after ${ms} ms`;
  }),
  // `set_alarm_in!(600 s)` on a clock 600 s ahead: `get_alarm!` is the time of the clock plus the delay (`pf.alarmIn`).
  check('Object set_alarm_in!: the alarm time is the clock of the shim plus the delay', async ({ get, skew }) => {
    const S = 600_000;
    await skew(S);
    const r = await get(`/objects/counter/alarm_in?name=clock&ms=${S}`);
    const m = /^set=Ok\(\{\}\) id=(\w+) t0=(\d+) alarm=Ok\((\d+)\)$/.exec(r.body);
    ok(m, `the answer: ${r.body}`);
    const [t0, alarm] = [Number(m[2]), Number(m[3])];
    ok(Math.abs(t0 - (Date.now() + S)) < 5000, `t0 ${t0} is not on the clock of the shim (${Date.now() + S})`);
    ok(alarm >= t0 + S && alarm < t0 + S + 2000, `get_alarm! ${alarm}, want ${t0 + S} + less than 2 s`);
    return `t0 ${t0}, alarm ${alarm}`;
  }),
];
