// The Tail Worker (MODULES.md 3, PLAN.md 8f): the `tail!` handler of conformance/TailRoutes.roc. The check starts a second
// Miniflare with two workers: a plain JS producer (`tails: ['tail']`), and the tail worker (the worker of the app). The log
// lines of the app (`trace`) say what `tail!` got. The producer logs, throws, runs a cron and logs 2 MiB.
import { fileURLToPath } from 'node:url';
import { eq, ok } from '../assert.mjs';

export const options = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MiB = 1024 * 1024;
const producer = `
export default {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/log-throw') {
      console.log('a', 1);
      throw new Error('boom');
    }
    if (path === '/big') {
      for (let i = 0; i < 50; i++) console.log('x'.repeat(40 * 1024));
      return new Response('big');
    }
    if (path === '/exotic') {
      console.log(1n, 'b');
      const loop = {}; loop.self = loop;
      console.log(loop);
      return new Response('exotic');
    }
    return new Response('ok');
  },
  async scheduled(controller) {
    console.log('cron', controller.cron);
  },
};`;

export const checks = [
  ['tail worker: setup (two workers in one Miniflare)', async (t) => {
    const logs = [];
    const mf = t.startMiniflare({
      workers: [
        { name: 'producer', modules: true, script: producer, tails: ['tail'] },
        // Each worker of a multi-worker config needs its own date, flags and modules root.
        { name: 'tail', modules: t.modules, modulesRoot: fileURLToPath(new URL('..', import.meta.url)), compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], d1Databases: ['DB'], kvNamespaces: ['KV'], durableObjects: { COUNTERS: { className: 'Counter', useSQLite: true } } },
      ],
      unsafeTriggerHandlers: true,
      handleStructuredLogs: (l) => logs.push(l),
    });
    await mf.ready;
    t.tail = { mf, logs };
  }],
  // PLAN.md 8f: the trace of a fetch that logs `console.log("a", 1)` and throws.
  ['tail the trace of a fetch that logs and throws', async (t) => {
    const r = await t.tail.mf.dispatchFetch('http://localhost/log-throw');
    await r.text();
    const l = await trace(t, (x) => x.request?.includes('/log-throw'));
    eq(l.outcome, 'exception', 'outcome');
    ok(/^"GET" http:\/\/localhost\/log-throw none headers=\d+ colo=\w+$/.test(l.request), `event: ${l.request}`);
    eq(l.logs, 1, 'logs');
    eq(l.first, 'log ["a",1]', 'the first log (level and message)');
    eq(JSON.stringify(l.exceptions), JSON.stringify(['Error: boom']), 'exceptions');
    eq(l.timestamp, 'set', 'event_timestamp_ms');
    return JSON.stringify(l);
  }],
  // The revert of the plan: `event` read for each kind, not only for a fetch.
  ['tail the trace of a scheduled run: no event, and the cron log', async (t) => {
    const r = await t.tail.mf.dispatchFetch('http://localhost/cdn-cgi/local/scheduled?cron=*+*+*+*+*');
    await r.text();
    const l = await trace(t, (x) => x.request === 'no event');
    eq(l.outcome, 'ok', 'outcome');
    eq(l.first, 'log ["cron","* * * * *"]', 'the first log');
    return JSON.stringify(l);
  }],
  ['tail a log message that JSON cannot write (a BigInt, a cycle) is its text', async (t) => {
    const r = await t.tail.mf.dispatchFetch('http://localhost/exotic');
    await r.text();
    const l = await trace(t, (x) => x.request?.includes('/exotic'));
    eq(l.logs, 2, 'logs');
    return JSON.stringify(l);
  }],
  ['tail a trace with 2 MiB of logs: the handler gets fewer logs, one warning', async (t) => {
    const r = await t.tail.mf.dispatchFetch('http://localhost/big');
    await r.text();
    const l = await trace(t, (x) => x.request?.includes('/big'));
    // workerd cuts the logs of one trace to about 200 kB (local). The shim of this worker has `tailMaxBytes` 100 kB (worker.js).
    ok(l.logs > 0 && l.log_bytes <= 100_000, `the handler got ${l.logs} logs of ${l.log_bytes} bytes`);
    let warns = [];
    for (let i = 0; i < 100 && !warns.length; i++) {
      warns = t.tail.logs.filter((x) => x.message.startsWith('tail: dropped'));
      await sleep(25);
    }
    eq(warns.length, 1, `warnings (the handler got ${l.logs} logs, ${l.log_bytes} bytes)`);
    ok(/^tail: dropped [1-9]\d* log lines: the batch is larger than 100000 bytes$/.test(warns[0].message.trim()), `the warning: ${warns[0].message}`);
    return `${l.logs} of 20 logs (${l.log_bytes} bytes); ${warns[0].message.trim()}`;
  }],
  ['tail teardown', async (t) => {
    await t.tail.mf.dispose();
  }],
];

// The `trace` lines of the tail worker (the app), the first that `pick` takes.
async function trace(t, pick) {
  const { logs } = t.tail;
  for (let i = 0; i < 400; i++) {
    const found = logs
      .map((l) => { try { return JSON.parse(l.message); } catch { return null; } })
      .find((x) => x?.msg === 'trace' && pick(x));
    if (found) return found;
    await sleep(25);
  }
  throw new Error(`no trace line; the log: ${JSON.stringify(logs.map((l) => l.message.slice(0, 120)).slice(-6))}`);
}
