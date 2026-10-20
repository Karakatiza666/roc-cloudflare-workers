// `Time` (MODULES.md 11, PLAN.md 8c): routes of conformance/TimeRoutes.roc.
import { answer, eq, ok } from '../assert.mjs';

export const options = {};

export const checks = [
  ['time now_ms!', async (t) => {
    const r = await t.get('/time/now');
    ok(r.status === 200 && Math.abs(Number(r.body) - Date.now()) < 5000, `got ${r.status} ${r.body}, want a time near ${Date.now()}`);
    return r.body;
  }],
  // PLAN.md 8c: `Time.sleep!(100)` takes one wait and about 100 ms.
  ['time sleep!', async (t) => {
    const r = await t.get('/time/sleep?ms=100');
    answer(r, 'slept');
    ok(r.waits === 1 && r.ms >= 95 && r.ms < 250, `${r.waits} waits, ${r.ms} ms: want 1 wait and about 100 ms`);
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  ['time sleep (Io twin)', async (t) => {
    const r = await t.get('/time/sleep_io?ms=100');
    answer(r, 'Ok({})');
    ok(r.waits === 1 && r.ms >= 95 && r.ms < 250, `${r.waits} waits, ${r.ms} ms: want 1 wait and about 100 ms`);
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  // API.md 6.5: a timeout is a race with `Time.sleep`. The 50 ms branch wins.
  ['time sleep in Io.race!', async (t) => {
    const r = await t.get('/time/race');
    answer(r, 'index=1 Ok(Fast)');
    ok(r.waits === 1 && r.ms >= 45 && r.ms < 250, `${r.waits} waits, ${r.ms} ms: want 1 wait and about 50 ms`);
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  // Io.timeout: a sleep in time is Ok, a sleep that is too long is TimedOut after about 40 ms (not 3 s: it is aborted).
  ['time Io.timeout: Ok when the sleep ends in time, TimedOut after the limit, the sleep is aborted', async (t) => {
    const r = await t.get('/time/timeout');
    answer(r, 'fast=Ok({}) slow=Err(Infra(TimedOut))');
    ok(r.ms >= 45 && r.ms < 600, `${r.ms} ms: want about 50 ms (the sleep of 3 s is aborted)`);
    eq(r.waits, 2, 'waits');
    return `${r.waits} waits, ${r.ms} ms`;
  }],
  // Io.timeout_at (N9): the deadline is a time on the `Time.now_ms!` clock. One check for each way to meet it.
  ['time Io.timeout_at: a deadline in 5 s that the sleep beats is Ok after about 10 ms', async (t) => {
    const r = await t.get('/time/timeout_at_win');
    answer(r, 'Ok({})');
    ok(r.ms >= 5 && r.ms < 600, `${r.ms} ms: want about 10 ms`);
    eq(r.waits, 1, 'waits');
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  ['time Io.timeout_at: a deadline in the past is TimedOut at once, the sleep of 3 s is aborted', async (t) => {
    const r = await t.get('/time/timeout_at_past');
    answer(r, 'Err(Infra(TimedOut))');
    ok(r.ms < 600, `${r.ms} ms: want about 0 ms (the sleep of 3 s is aborted)`);
    eq(r.waits, 1, 'waits');
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  ['time Io.timeout_at: a deadline in 100 ms is TimedOut at about 100 ms, not before', async (t) => {
    const r = await t.get('/time/timeout_at_wait');
    answer(r, 'Err(Infra(TimedOut))');
    ok(r.ms >= 90 && r.ms < 600, `${r.ms} ms: want about 100 ms (not 0 ms, not the 3 s of the sleep)`);
    eq(r.waits, 1, 'waits');
    return `${r.waits} wait, ${r.ms} ms`;
  }],
  ['time Io.timeout_at: a deadline of U64.highest does not throw, the operation wins', async (t) => {
    const r = await t.get('/time/timeout_at_huge');
    answer(r, 'Ok({})');
    ok(r.ms < 600, `${r.ms} ms: want about 10 ms`);
    return `${r.waits} wait, ${r.ms} ms`;
  }],
];
