// `Memo` (MODULES.md 9): routes of conformance/MemoRoutes.roc. `load!` makes a new id each time, so the same id in two
// requests shows that the second request ran no `load!`.
import { answer, eq, ok } from '../assert.mjs';

const value = /^Ok kid=k1 big=1152921504606846976 made=([0-9a-f-]{36})$/;

export const checks = [
  // PLAN.md 8c: a second request gets the value with no `load!`; a U64 of 2^60 comes back exact.
  ['memo get!: a second request gets the value with no load!', async (t) => {
    answer(await t.get('/memo/clear'), 'cleared');
    const a = await t.get('/memo/get');
    const ma = value.exec(a.body);
    ok(a.status === 200 && ma, `first: got ${a.status} ${a.body}`);
    const b = await t.get('/memo/get');
    const mb = value.exec(b.body);
    ok(b.status === 200 && mb, `second: got ${b.status} ${b.body}`);
    eq(mb[1], ma[1], 'the id of the second request (a new id: load! ran)');
    // The first request: pinned (miss), random_uuid, pin. The second: pinned only. No wait.
    eq(a.waits + b.waits, 0, 'waits');
    eq(b.calls, 1, 'crossings of the second request');
    return `same id ${mb[1]}, the second request: ${b.calls} call!, 0 waits`;
  }],
  ['memo clear!: the next get! loads again', async (t) => {
    const a = value.exec((await t.get('/memo/get')).body);
    answer(await t.get('/memo/clear'), 'cleared');
    const b = value.exec((await t.get('/memo/get')).body);
    ok(a && b && a[1] !== b[1], 'the same id after clear!');
  }],
  ['memo max_age_ms: a get! after the age loads again', async (t) => answer(await t.get('/memo/short'), 'same=False')],
];
