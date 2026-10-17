// PLAN.md 11c and 5d on the edge app (edge/deploy.sh, routes of edge/EdgeRoutes.roc). Each part prints JSON lines: the
// answers of the client, `/__edge` of the isolate (its id, the flags of 5a, the runner counters), and the `wrangler tail`
// events of its requests (outcome, cpuTime, wallTime, logs, exceptions).
//   EDGE=https://rocplat-test-app.<sub>.workers.dev node edge/probe-11c.mjs <part ...>
// Parts: shacpu (8g, on the 8g Worker), cpu (5d), mem (128 MB, wasm), jsmem (128 MB, JS), after (request.signal after a whole body), writer (a stream past 30 s),
// away (the client goes away from an open stream), fetch8d (8d texts of a closed port, a DNS failure, a host that does not answer).
import { spawn } from 'node:child_process';

const EDGE = process.env.EDGE.replace(/\/$/, '');
const parts = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = (o) => console.log(JSON.stringify(o));
const events = [];
const tail = spawn('wrangler', ['tail', new URL(EDGE).hostname.split('.')[0], '--format', 'json'], { stdio: ['ignore', 'pipe', 'ignore'] });
let buf = '';
tail.stdout.on('data', (d) => {
  buf += d;
  for (;;) {
    const end = buf.indexOf('\n}\n');
    if (end < 0) break;
    try { events.push(JSON.parse(buf.slice(0, end + 2))); } catch {}
    buf = buf.slice(end + 3);
  }
});
const brief = (e) => ({
  url: e.event?.request?.url?.replace(EDGE, ''), cron: e.event?.cron, outcome: e.outcome, cpuTime: e.cpuTime, wallTime: e.wallTime,
  status: e.event?.response?.status, logs: (e.logs ?? []).map((l) => `${l.level}: ${l.message.join(' ')}`.slice(0, 300)),
  exceptions: (e.exceptions ?? []).map((x) => `${x.name}: ${x.message}`.slice(0, 300)),
});
const eventsFor = (needle) => events.filter((e) => (e.event?.request?.url ?? '').includes(needle)).map(brief);
const get = async (path, init) => {
  const t0 = performance.now();
  try {
    const r = await fetch(EDGE + path, init);
    const body = await r.text();
    return { path, status: r.status, ms: Math.round(performance.now() - t0), body: path === '/__edge' ? body : body.slice(0, 300), ray: r.headers.get('cf-ray') };
  } catch (e) {
    return { path, error: String(e.cause ?? e.message), ms: Math.round(performance.now() - t0) };
  }
};
const edge = async () => JSON.parse((await get('/__edge')).body);
// `/__edge` exists only on the app Worker.
await sleep(7000); // the tail connects

for (const part of parts) {
  const tag = `${part}-${Date.now().toString(36)}`;
  out({ part, tag, start: new Date().toISOString() });
  if (part === 'cpu') {
    out({ before: await edge() });
    for (const n of [10_000, 30_000, 100_000, 300_000, 1_000_000, 3_000_000, 10_000_000, 30_000_000]) {
      const r = await get(`/edge/spin?n=${n}&tag=${tag}`);
      out({ spin: n, ...r });
      out({ after: await edge() });
      if (r.status !== 200) {
        await get('/edge/spin?n=1');
        out({ next: await edge() });
      }
    }
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'mem') {
    out({ before: await edge() });
    for (const mb of [16, 48, 96, 128, 192]) {
      // A witness request in flight (a wait of 4 s), then the grow (held 2 s) on the same connection pool.
      const witness = get(`/time/sleep?ms=4000&tag=${tag}-w${mb}`);
      await sleep(300);
      const g = await get(`/edge/grow?mb=${mb}&hold=2000&tag=${tag}`);
      out({ grow: mb, ...g, witness: await witness });
      out({ after: await edge() });
    }
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'jsmem') {
    // The same with JS memory (`/__jsgrow` of edge/worker.js), not wasm memory.
    out({ before: await edge() });
    for (const mb of [64, 112, 160]) {
      const witness = get(`/time/sleep?ms=4000&tag=${tag}-w${mb}`);
      await sleep(300);
      const g = await get(`/__jsgrow?mb=${mb}&hold=2000&tag=${tag}`);
      out({ jsgrow: mb, ...g, witness: await witness });
      out({ after: await edge() });
    }
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'shacpu') {
    // 8g on the edge Worker of edge/deploy-8g.sh (EDGE=its URL): the cpuTime of `wrangler tail` for SHA-256 of 1 MB,
    // the builtin in wasm against `crypto.subtle.digest`. Is the time of `digest` CPU time of the request?
    for (const [name, n] of [['wasm', 4], ['digest', 4], ['digest', 16], ['wasm', 0], ['digest', 0]]) {
      for (let i = 0; i < 3; i++) out({ sha: name, n, ...(await get(`/sha/${name}?size=1048576&n=${n}&tag=${tag}-${i}`)) });
    }
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'after') {
    // The client reads the whole body, then goes away. The task waits 40 times 1 s after `respond!`.
    const ac = new AbortController();
    const r = await fetch(`${EDGE}/edge/after?s=40&tag=${tag}`, { signal: ac.signal });
    out({ status: r.status, body: await r.text() });
    ac.abort();
    await sleep(50_000);
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'writer') {
    // A stream of 40 lines, one each second: past the 30 s of `waitUntil`.
    const t0 = Date.now();
    const r = await fetch(`${EDGE}/edge/writer?s=40&tag=${tag}`);
    const reader = r.body.getReader();
    let lines = 0, text = '', err = null;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        text += Buffer.from(value).toString();
        lines = text.split('\n').filter(Boolean).length;
      }
    } catch (e) { err = String(e.cause ?? e.message); }
    out({ status: r.status, lines, last: text.trim().split('\n').pop(), seconds: (Date.now() - t0) / 1000, err });
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
  if (part === 'away') {
    // The client reads 3 lines of a stream of 20, then goes away.
    const ac = new AbortController();
    const r = await fetch(`${EDGE}/edge/writer?s=20&tag=${tag}`, { signal: ac.signal });
    const reader = r.body.getReader();
    let text = '';
    while (text.split('\n').filter(Boolean).length < 3) {
      const { value } = await reader.read();
      text += Buffer.from(value).toString();
    }
    ac.abort();
    out({ read: text.trim().split('\n'), abortedAt: new Date().toISOString() });
    await sleep(30_000);
    for (const e of eventsFor(tag)) out({ tail: e });
    out({ edge: await edge() });
  }
  if (part === 'fetch8d') {
    const q = encodeURIComponent;
    for (const url of ['http://1.1.1.1:1/', 'http://no-such-host.invalid/', 'https://10.255.255.1/', `${process.env.SERVER}/hang`, 'not a url']) {
      out({ url, ...(await get(`/http/send?url=${q(url)}&tag=${tag}`)) });
    }
    await sleep(Number(process.env.TAIL_WAIT ?? 20000));
    for (const e of eventsFor(tag)) out({ tail: e });
  }
}
tail.kill();
process.exit(0);
