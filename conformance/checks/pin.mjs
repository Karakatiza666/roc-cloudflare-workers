// The pin table (API.md RS2): routes of conformance/PinRoutes.roc. `Io.pin!`, `pinned!` and `unpin!` are each one
// `call!` (no wait).
import { answer, eq, ok } from '../assert.mjs';

export const options = {};

export const checks = [
  ['pin pin!, pinned!, unpin!: one call! each, no wait', async (t) => {
    const a = await t.get('/pin/pin?name=p1&v=hello');
    answer(a, 'Ok({})');
    const b = await t.get('/pin/pinned?name=p1');
    answer(b, 'Ok(Text("hello"))');
    answer(await t.get('/pin/unpin?name=p1'), 'unpinned');
    const c = await t.get('/pin/pinned?name=p1');
    answer(c, 'Err(NotPinned)');
    for (const r of [a, b, c]) {
      eq(r.waits + r.awaits, 0, 'waits');
      eq(r.calls, 1, 'crossings (js_call)');
    }
  }],
  ['pin pinned! of a name with no entry is NotPinned', async (t) => answer(await t.get('/pin/pinned?name=never'), 'Err(NotPinned)')],
  ['pin max_age_ms: pinned! after the age is NotPinned', async (t) => answer(await t.get('/pin/age?name=p2'), 'Ok(Int(7)) Err(NotPinned)')],
  // RS2: the table has a limit of entries (shim option pinLimit, default 1,000). Earlier checks (memo) keep some
  // entries, so the route pins a little less than 1,000. It unpins all its entries.
  ['pin pin! to a full table is PinErr', async (t) => {
    const r = await t.get('/pin/full');
    const m = /^pinned=(\d+) PinErr RangeError: pin: the pin table is full \(1000 entries, shim option pinLimit\)$/.exec(r.body);
    ok(r.status === 200 && m && Number(m[1]) > 900 && Number(m[1]) <= 1000, `got ${r.status} ${r.body}`);
    return r.body;
  }],
];
