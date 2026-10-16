// PLAN.md 3a, 3b: the JS task table alone (bench/tasks.js), with a fake clock. No wasm.
// node bench/tasks-test.mjs
// Each rule of the deadline table of API.md 10.2, also the rules that need later steps
// (respond!, Body.writer!, 101 sockets, receive!: 8b, 8f). Deadlines: wait 100 ms,
// wall 200 ms, Init 150 ms, after respond 100 ms.
import { makeTaskTable, deadlineOf, DEADLINES } from './tasks.js';
let failed = false;
const row = (name, got, want) => {
  const pass = JSON.stringify(got) === JSON.stringify(want);
  if (!pass) failed = true;
  console.log(`${pass ? 'ok  ' : 'FAIL'} ${name}: ${JSON.stringify(got)}${pass ? '' : ` (want ${JSON.stringify(want)})`}`);
};
let clock = 0;
const opts = { taskDeadlineMs: 100, wallMs: 200, initMs: 150, afterRespondMs: 100, now: () => clock };
const table = () => { clock = 0; return makeTaskTable(opts); };
// Run `t` to time `ms`, one sweep each 10 ms. Returns the time of its cancel, or null.
const until = (tb, t, ms) => {
  for (; clock <= ms; clock += 10) { tb.sweep(); if (t.cancelled) return clock; }
  return null;
};

row('defaults (API.md 10.2)', DEADLINES, { taskDeadlineMs: 120000, wallMs: 900000, initMs: 30000, afterRespondMs: 30000 });

// Fetch before respond!: each wait has the wait deadline. Time with no wait does not count.
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  clock = 500; // runs 500 ms with no wait
  tb.waitStart(t);
  row('Fetch: a wait of 300 ms is cancelled 100 ms after it starts', until(tb, t, 800), 600);
  row('Fetch: reason', t.reason, 'deadline');
}
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  tb.waitStart(t); clock = 90; tb.waitStop(t);
  tb.waitStart(t); clock = 180; tb.waitStop(t);
  row('Fetch: two waits of 90 ms each: not cancelled', until(tb, t, 400), null);
}
// Scheduled, Queue, Alarm: the whole task, 200 ms; one wait has no deadline.
for (const kind of ['Scheduled', 'Queue', 'Alarm']) {
  const tb = table();
  const t = tb.begin('i', { kind });
  tb.waitStart(t);
  row(`${kind}: one wait of 190 ms is not cancelled`, until(tb, t, 190), null);
  row(`${kind}: cancelled at the wall limit`, until(tb, t, 400), 200);
}
// Init of an object: the whole task, 150 ms.
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Init' });
  row('Init: cancelled 150 ms from its start, also with no wait', until(tb, t, 400), 150);
}
// Other kinds: the wait deadline, as Fetch.
for (const kind of ['Email', 'Tail', 'Rpc', 'EntrypointFetch']) {
  const tb = table();
  const t = tb.begin('i', { kind });
  clock = 50; tb.waitStart(t);
  row(`${kind}: the wait deadline`, until(tb, t, 400), 150);
}
// After respond! with a complete body (Empty, Text, Bytes): 100 ms after respond!, waits or not.
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  clock = 20; tb.respond(t);
  tb.waitStart(t);
  row('respond: a wait after respond! is cancelled 100 ms after respond!', until(tb, t, 400), 120);
}
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  clock = 20; tb.respond(t);
  clock = 50; tb.waitStart(t); clock = 110; tb.waitStop(t); // a wait of 60 ms, under the wait deadline
  row('respond: also with no wait at the limit (cancel at the next wait)', until(tb, t, 400), 120);
}
// A Body.writer! stream: open while the task writes, complete at close!.
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  clock = 10; tb.respond(t, true);
  for (; clock < 310; clock += 10) { tb.waitStart(t); clock += 5; tb.waitStop(t); tb.sweep(); } // writes for 300 ms
  row('writer: a task that writes for 300 ms is not cancelled', t.cancelled, false);
  tb.bodyComplete(t); // close!
  const at = clock;
  tb.waitStart(t);
  row('writer: a wait after close! is cancelled 100 ms after close!', until(tb, t, 800) - at, 100);
}
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  tb.respond(t, true);
  tb.waitStart(t);
  row('writer: one wait of 300 ms while the stream is open: no wait deadline', until(tb, t, 300), null);
}
// A 101 response: open while the socket is open, complete when it closes.
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  tb.respond(t, true);
  tb.waitStart(t, true); // receive!
  row('101: the socket is open 300 ms: not cancelled', until(tb, t, 300), null);
  tb.waitStop(t);
  tb.bodyComplete(t); // the socket closed
  const at = clock;
  row('101: ends 100 ms after the socket closes', until(tb, t, 800) - at, 100);
}
// A socket wait has no deadline, in each state.
for (const [name, setup] of [
  ['Fetch before respond!', (tb, t) => {}],
  ['Scheduled', null],
  ['after respond!', (tb, t) => tb.respond(t)],
]) {
  const tb = table();
  const t = tb.begin('i', { kind: name === 'Scheduled' ? 'Scheduled' : 'Fetch' });
  setup?.(tb, t);
  tb.waitStart(t, true);
  row(`socket: a receive! of 300 ms, ${name}: not cancelled`, until(tb, t, 300), null);
}
{
  const tb = table();
  const t = tb.begin('i', { kind: 'Fetch' });
  tb.waitStart(t, false);
  row('socket revert check: the same wait not on a socket is cancelled', until(tb, t, 300), 100);
}
// Signals: cancel at once.
{
  const tb = table();
  const ac = new AbortController();
  const t = tb.begin('i', { signal: ac.signal });
  let woke = false;
  tb.waitStart(t).then(() => (woke = true));
  ac.abort();
  await null;
  row('signal: request.signal aborts: cancelled at once, the wait wakes', [t.cancelled, t.reason, woke], [true, 'signal', true]);
  tb.end(t);
  const ac2 = new AbortController();
  ac2.abort();
  const t2 = tb.begin('i', { signal: ac2.signal });
  row('signal: a signal that aborted before the task starts', [t2.cancelled, t2.reason], [true, 'signal']);
}
{
  const tb = table();
  const ac = new AbortController();
  const t = tb.begin('i', { signal: ac.signal });
  tb.end(t);
  ac.abort();
  row('signal: no cancel after the task ended', [t.cancelled, tb.stats.cancels], [false, 0]);
}
for (const reason of ['socket', 'stream']) {
  const tb = table();
  const t = tb.begin('i');
  tb.waitStart(t);
  tb.cancel(t, reason);
  row(`${reason}: the close of its socket / the cancel of its stream cancels at once`, [t.cancelled, t.reason, tb.stats.byReason], [true, reason, { [reason]: 1 }]);
}
// A replace cancels only the tasks of the old instance.
{
  const tb = table();
  const a = [1, 2, 3].map(() => tb.begin('old'));
  const b = tb.begin('new');
  row('replace: cancelAll', [tb.cancelAll('old'), a.every((t) => t.cancelled), b.cancelled], [3, true, false]);
}
// Slots: a shed above the limit, per instance; a slot is free again at end.
{
  const tb = table();
  const got = Array.from({ length: 5 }, () => tb.begin('i', { slots: 3 }));
  row('slots: 3 of 5 start', got.map((t) => !!t), [true, true, true, false, false]);
  row('slots: another instance has its own slots', !!tb.begin('j', { slots: 3 }), true);
  tb.end(got[0]);
  row('slots: a slot is free after end', !!tb.begin('i', { slots: 3 }), true);
  row('slots: shed count', tb.stats.shed, 2);
}
// Ids: not 0, unique among tasks in flight, wrap below 0xFFFFFFFF.
{
  const tb = table();
  const t1 = tb.begin('i');
  const ids = new Set([t1.id]);
  for (let i = 0; i < 1000; i++) { const t = tb.begin('i'); ids.add(t.id); tb.end(t); }
  row('id: first id 1, ids unique', [t1.id, ids.size], [1, 1001]);
}
// deadlineOf is pure: same input, same output.
row('deadlineOf: no wait, Fetch', deadlineOf({ kind: 'Fetch', waiting: false, response: 'none' }), Infinity);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
