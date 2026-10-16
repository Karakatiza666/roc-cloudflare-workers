// `Time` (MODULES.md 11, PLAN.md 8c): routes of conformance/TimeRoutes.roc.
import { answer, ok } from '../assert.mjs';

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
];
