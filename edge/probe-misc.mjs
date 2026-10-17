// PLAN.md 11c, 8f part 3 and part 2 on the edge app: a WebSocket of the Worker open past 30 s after its 101 (with a
// receive! that waits 40 s on the socket), `connect!` to a public wss server, the version metadata, and a `Queue.v8`
// message to the JS consumer (the consumer logs what it got: it can run in another isolate).
//   EDGE=https://rocplat-test-app.<sub>.workers.dev node edge/probe-misc.mjs
import { spawn } from 'node:child_process';

const EDGE = process.env.EDGE.replace(/\/$/, '');
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
await sleep(7000);

// A WebSocket of the Worker: a message now, then 40 s of no traffic (receive! waits on the socket), then a message.
const ws = new WebSocket(`${EDGE.replace('https:', 'wss:')}/websocket/echo`);
const got = [];
ws.onmessage = (m) => got.push([Date.now(), String(m.data)]);
const closed = new Promise((r) => { ws.onclose = (e) => r({ code: e.code, reason: e.reason, at: Date.now() }); });
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
const t0 = Date.now();
ws.send('a');
await sleep(40_000);
ws.send('b after 40 s');
await sleep(3000);
ws.send('close');
const c = await Promise.race([closed, sleep(10_000).then(() => 'no close')]);
out({ websocket: got.map(([t, m]) => `${Math.round((t - t0) / 1000)} s: ${m}`), close: c });

const get = async (path) => { const r = await fetch(EDGE + path); return `${r.status} ${(await r.text()).slice(0, 300)}`; };
for (const url of ['wss://echo.websocket.org', 'https://echo.websocket.org']) out({ client: url, answer: await get(`/websocket/client?url=${encodeURIComponent(url)}`) });
out({ version: await get('/version/metadata') });
out({ v8: await get('/queue/v8') });
await sleep(30_000);
for (const e of events) {
  const logs = (e.logs ?? []).map((l) => l.message.join(' ')).filter((m) => m.includes('v8 seen') || m.includes('echo closed'));
  if (logs.length) out({ tail: e.event?.request?.url ?? e.event?.queue ?? 'other', outcome: e.outcome, logs });
}
tail.kill();
process.exit(0);
