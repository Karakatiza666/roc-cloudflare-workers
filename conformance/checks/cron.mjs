// Crons of Worker.new (MODULES.md 3): the handler of `Worker.cron` first, else `scheduled!`. The app (conformance/app.roc)
// has `Worker.cron("cron-a", cron_a!)`, which logs "cron handler", and a `scheduled!` that fails for "bad" only. The case with
// neither (Unhandled) needs an app with no `scheduled!`: bench/bindings-test.mjs.
import { eq, ok } from '../assert.mjs';

export const options = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const handled = (t, cron) => t.logs.filter((l) => String(l.message).includes('"msg":"cron handler"') && String(l.message).includes(`"cron":"${cron}"`)).length;
const failedLine = (t, text) => t.logs.some((l) => String(l.message).includes(text));
const run = (t, cron) => t.mf.dispatchFetch(`http://localhost/cdn-cgi/local/scheduled?cron=${encodeURIComponent(cron)}`);

export const checks = [
  ['cron Worker.cron: the run of its expression goes to its handler, not to scheduled!', async (t) => {
    const before = handled(t, 'cron-a');
    const r = await run(t, 'cron-a');
    eq(r.status, 200, 'status');
    for (let i = 0; i < 40 && handled(t, 'cron-a') === before; i++) await sleep(25);
    eq(handled(t, 'cron-a'), before + 1, 'runs of the cron handler');
  }],
  ['cron an expression with no Worker.cron goes to scheduled! (it fails for bad, and the cron handler does not run)', async (t) => {
    const before = handled(t, 'bad');
    const r = await run(t, 'bad');
    ok(r.status !== 200, `status ${r.status}`);
    for (let i = 0; i < 40 && !failedLine(t, 'scheduled: failed: UnknownCron("bad")'); i++) await sleep(25);
    ok(failedLine(t, 'scheduled: failed: UnknownCron("bad")'), 'no log line of scheduled! for "bad"');
    eq(handled(t, 'bad'), before, 'runs of the cron handler for "bad"');
    const good = await run(t, 'good');
    eq(good.status, 200, 'an unknown cron that scheduled! accepts');
    await sleep(100);
    eq(handled(t, 'good'), 0, 'runs of the cron handler for "good"');
  }],
];
