// `Queue` (MODULES.md 6, PLAN.md 8f): routes and the consumer of conformance/QueueRoutes.roc. The producer is a Miniflare queue
// binding, and the consumer is the `queue!` of the app: it writes one log line for each message. A check that needs exact
// acks and retries calls the `queue` handler of the worker directly (`worker.queue(name, messages)`), and reads what the
// handler acked and retried. The queue `v8` has a JS consumer (`worker.js`).
import { answer, eq, ok } from '../assert.mjs';

export const options = {
  queueProducers: { JOBS: 'jobs', TEXTS: 'texts', BIN: 'bin', V8Q: 'v8' },
  queueConsumers: {
    jobs: { maxBatchSize: 20, maxBatchTimeout: 0.1, maxRetries: 3, retryDelay: 0 },
    texts: { maxBatchSize: 5, maxBatchTimeout: 0.1 },
    bin: { maxBatchSize: 5, maxBatchTimeout: 0.1 },
    v8: { maxBatchSize: 5, maxBatchTimeout: 0.1 },
  },
};

const id = () => Math.random().toString(36).slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The log lines of workerd that are a JSON object, with their time.
const lines = (t, msg, label) =>
  t.logs
    .map((l) => {
      try {
        return { ...JSON.parse(l.message), level: l.level };
      } catch {
        return null;
      }
    })
    .filter((l) => l && l.msg === msg && (label === undefined || l.label === label || l.s === label));
// Waits until `n` lines with this message and label are in the log (workerd writes a line after the response).
async function lines_n(t, msg, label, n, ms = 8000) {
  const from = Date.now();
  while (Date.now() - from < ms) {
    const l = lines(t, msg, label);
    if (l.length >= n) return l;
    await sleep(25);
  }
  throw new Error(`${lines(t, msg, label).length} of ${n} log lines "${msg}" ${label}`);
}
const msg = (id, body, attempts = 1) => ({ id, timestamp: new Date(1_700_000_000_000), body, attempts });
const call = async (t, queue, messages) => (await t.mf.getWorker()).queue(queue, messages);

export const checks = [
  // PLAN.md 8f: a `Queue(a)` constant sends a message that `each!` reads as the same type.
  ['queue send!, and each! reads the same type', async (t) => {
    const label = id();
    answer(await t.get(`/queue/send?n=7&label=${label}`), 'Ok');
    const [l] = await lines_n(t, 'job', label, 1);
    eq(JSON.stringify([l.n, l.label, l.attempts]), JSON.stringify([7, label, 1]), 'the job');
    return `n=${l.n} attempts=${l.attempts}`;
  }],
  ['queue send (Io twin), send_with! and twin', async (t) => {
    const label = id();
    answer(await t.get(`/queue/send_io?n=1&label=${label}-a`), 'Ok');
    answer(await t.get(`/queue/send_with?n=2&label=${label}-b&delay=0`), 'Ok');
    answer(await t.get(`/queue/send_with_io?n=3&label=${label}-c&delay=0`), 'Ok');
    for (const [s, n] of [['a', 1], ['b', 2], ['c', 3]]) eq((await lines_n(t, 'job', `${label}-${s}`, 1))[0].n, n, `job ${s}`);
  }],
  ['queue text and bytes', async (t) => {
    const label = id();
    answer(await t.get(`/queue/text?s=${label}`), 'Ok');
    eq((await lines_n(t, 'text', label, 1))[0].attempts, 1, 'attempts of the text');
    answer(await t.get('/queue/bytes'), 'Ok');
    const from = Date.now();
    while (!lines(t, 'bytes').length && Date.now() - from < 8000) await sleep(25);
    const b = lines(t, 'bytes')[0];
    eq(JSON.stringify([b.len, b.last]), JSON.stringify([3, 255]), 'the bytes');
  }],
  // PLAN.md 8f: a body that is not an `a` is retried, not acked.
  ['queue each!: a body that is not an a is retried, not acked', async (t) => {
    const r = await call(t, 'jobs', [msg('bad', { wrong: 'shape' }), msg('good', { n: 4, label: `${id()}` })]);
    eq(JSON.stringify((r.retryMessages ?? []).map((x) => x.msgId)), JSON.stringify(['bad']), 'retried');
    eq(JSON.stringify(r.explicitAcks), JSON.stringify(['good']), 'acked');
    eq(r.retryBatch.retry, false, 'retryBatch');
    return `outcome ${r.outcome}, retried bad, acked good`;
  }],
  // PLAN.md 8f: `Message.ack!` of the second message acks only it (`pf.findById`).
  ['queue Message.ack! of the second message acks only it', async (t) => {
    const r = await call(t, 'ack-second', [msg('m1', 1), msg('m2', 2), msg('m3', 3)]);
    eq(JSON.stringify(r.explicitAcks), JSON.stringify(['m2']), 'acked');
    eq((r.retryMessages ?? []).length, 0, 'retried');
    eq(r.ackAll, false, 'ackAll');
  }],
  ['queue Message.retry_with! and the batch functions: delaySeconds rounds up', async (t) => {
    const a = await call(t, 'retry-second-with', [msg('m1', 1), msg('m2', 2)]);
    eq(JSON.stringify(a.retryMessages), JSON.stringify([{ msgId: 'm2', delaySeconds: 3 }]), 'retry_with! (2,500 ms)');
    const b = await call(t, 'retry-all-with', [msg('m1', 1)]);
    eq(JSON.stringify(b.retryBatch), JSON.stringify({ retry: true, delaySeconds: 2 }), 'retry_all_with! (1,500 ms)');
    const c = await call(t, 'retry-all', [msg('m1', 1)]);
    eq(c.retryBatch.retry, true, 'retry_all!');
    ok(c.retryBatch.delaySeconds === undefined, `retry_all! has no delay: ${JSON.stringify(c.retryBatch)}`);
    const d = await call(t, 'ack-all', [msg('m1', 1)]);
    eq(d.ackAll, true, 'ack_all!');
  }],
  ['queue queue!: an Err is a throw, so Workers retries the batch', async (t) => {
    const r = await call(t, 'handler-err', [msg('m1', 1)]);
    eq(r.outcome, 'exception', 'outcome');
    return JSON.stringify(r);
  }],
  // PLAN.md 8f: `each!` gives `msg.attempts` 1 then 2 after an `Err`.
  ['queue each!: msg.attempts is 1, then 2 after an Err', async (t) => {
    const label = `fail-once-${id()}`;
    answer(await t.get(`/queue/send?n=9&label=${label}`), 'Ok');
    const l = await lines_n(t, 'job', label, 2);
    eq(JSON.stringify(l.map((x) => x.attempts)), JSON.stringify([1, 2]), 'attempts');
    const w = lines(t, 'queue message failed').find((x) => String(x.error).includes(label));
    ok(w && w.level === 'warn' && w.attempts === 1, `no warning for the first attempt: ${JSON.stringify(w)}`);
    return `attempts ${l.map((x) => x.attempts)}, warning: ${w.error}`;
  }],
  // PLAN.md 8f: `send_batch_with!` with `delay_ms`.
  ['queue send_batch! and send_batch_with! with delay_ms', async (t) => {
    const now = id();
    const late = `late-${id()}`, early = `early-${id()}`;
    const t0 = Date.now();
    answer(await t.get(`/queue/batch_with?count=3&label=${late}&delay=2500`), 'Ok');
    answer(await t.get(`/queue/batch?count=3&label=${early}`), 'Ok');
    answer(await t.get(`/queue/batch_io?count=1&label=${early}-io`), 'Ok');
    answer(await t.get(`/queue/batch_with_io?count=1&label=${late}-io&delay=0`), 'Ok');
    await lines_n(t, 'job', early, 3);
    const first = Date.now() - t0;
    eq(lines(t, 'job', late).length, 0, 'a delayed message came early');
    const got = await lines_n(t, 'job', late, 3);
    const ms = Date.now() - t0;
    ok(ms >= 2400, `the delayed batch came after ${ms} ms`);
    eq(got.map((x) => x.n).sort().join(), '0,1,2', 'the messages');
    return `immediate batch after ${first} ms, delayed batch after ${ms} ms${now ? '' : ''}`;
  }],
  // PLAN.md 8f: `send_batch!` of 101 messages is `QueueErr`. The text of the throw: local `Unknown Internal Error (15000)`, edge
  // (`t.edge`, PLAN.md 11c, E39) `batch message count of 101 exceeds limit of 100 (10206)`.
  ['queue send_batch! of 101 messages is QueueErr', async (t) => {
    const r = await t.get(`/queue/batch?count=101&label=${id()}`);
    ok(r.status === 200 && r.body.startsWith('Err QueueErr'), `got ${r.status} ${r.body.slice(0, 200)}`);
    const text = t.edge ? 'batch message count of 101 exceeds limit of 100 (10206)' : 'Unknown Internal Error (15000)';
    ok(r.body.includes(text), `got ${r.body.slice(0, 200)}, want the text ${text}`);
    return r.body.slice(0, 160);
  }],
  // PLAN.md 8f: a `Queue.v8` message with a `Cbor.Bytes` field reaches a JS consumer as `Uint8Array`.
  ['queue v8: a Cbor.Bytes field reaches a JS consumer as Uint8Array', async (t) => {
    answer(await t.get('/queue/v8'), 'Ok');
    let seen = [];
    for (let i = 0; i < 400 && !seen.length; i++) {
      seen = JSON.parse((await t.get('/__queue_seen')).body);
      await sleep(25);
    }
    ok(seen.length, 'the JS consumer got no message');
    const m = seen[seen.length - 1];
    eq(JSON.stringify([m.n, m.big, m.isUint8Array, m.data]), JSON.stringify([5, 'bigint 1152921504606846976', true, [1, 2, 3]]), 'the message');
    return `n=${m.n} big=${m.big} Uint8Array=${m.isUint8Array}`;
  }],
];
