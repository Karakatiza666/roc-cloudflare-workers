// The facts of local workerd (Miniflare of the global wrangler) for the close record and the extensions of a WebSocket
// (PLAN.md "Status of the WebSocket close record and extensions"), in plain JS with no platform:
// 1. A client socket (`fetch` with `Upgrade`) to a Node `ws` echo server: send, wait for the echo, `close(1000, '')`, wait
//    for the close event. The events in order, and the properties of the error of an `error` event. With a busy step of
//    20 ms after `close()`, and with none.
// 2. The events of a drop of the server with no close frame, and of a frame with RSV bits (a protocol error).
// 3. `Sec-WebSocket-Extensions`: a client of workerd to servers with and without `permessage-deflate`, with and without
//    an offer of the app; a Node client that offers `permessage-deflate` to a `WebSocketPair` of a Worker.
//   node research/ws-close-probe/probe.mjs   (output: research/ws-close-probe/out.txt)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const req = createRequire(import.meta.url);
const { Miniflare, convertV4MiniflareOptions } = req(mfDir);
const W = req(join(dirname(mfDir), 'ws'));
const server = (pmd) => new Promise((r) => {
  const s = new W.WebSocketServer({ port: 0, host: '127.0.0.1', perMessageDeflate: pmd });
  s.on('connection', (ws, rq) => ws.on('message', (m) => {
    const t = String(m);
    if (t === 'drop') ws.terminate();
    else if (t === 'rsv') ws._socket.write(Buffer.from([0xf1, 0x00]));
    else ws.send(`echo ${t} offer=${rq.headers['sec-websocket-extensions'] ?? '-'} ext=${ws.extensions}`);
  }));
  s.once('listening', () => r(s));
});
const on = await server(true);
const off = await server(false);

const script = `
const errProps = (x) => x && JSON.stringify(Object.fromEntries(Object.getOwnPropertyNames(x).filter((k) => k !== 'stack').map((k) => [k, x[k]])));
async function events(url, first, busy) {
  const res = await fetch(url, { headers: { Upgrade: 'websocket' } });
  const ws = res.webSocket;
  ws.accept();
  const ev = [];
  let wake;
  const next = () => new Promise((r) => (wake = r));
  const closed = () => ev.some((x) => x.startsWith('close'));
  ws.addEventListener('message', () => { ev.push('message'); wake?.(); });
  ws.addEventListener('close', (e) => { ev.push('close ' + e.code + ' clean=' + e.wasClean); wake?.(); });
  ws.addEventListener('error', (e) => { ev.push('error "' + e.message + '" ' + errProps(e.error) + ' readyState=' + ws.readyState); wake?.(); });
  ws.send(first);
  if (first === 'still') {
    await next();
    ws.close(1000, '');
    if (busy) { const t0 = Date.now(); while (Date.now() - t0 < 20); }
  }
  const t0 = Date.now();
  while (!closed() && Date.now() - t0 < 2000) await Promise.race([next(), scheduler.wait(2000)]);
  if (!closed()) ev.push('no close event in 2 s, readyState=' + ws.readyState);
  return ev.join(' | ');
}
export default { async fetch(request) {
  const u = new URL(request.url);
  const q = (k) => u.searchParams.get(k);
  if (u.pathname === '/events') return new Response(await events(q('url'), q('first'), q('busy') === '1'));
  if (u.pathname === '/pair') {
    const [c, s] = Object.values(new WebSocketPair());
    s.accept();
    s.addEventListener('message', () => s.send('server end: extensions=' + JSON.stringify(s.extensions) + ' offer of the request=' + JSON.stringify(request.headers.get('sec-websocket-extensions'))));
    return new Response(null, { status: 101, webSocket: c });
  }
  const h = { Upgrade: 'websocket' };
  if (q('offer')) h['Sec-WebSocket-Extensions'] = q('offer');
  const res = await fetch(q('url'), { headers: h });
  const ws = res.webSocket;
  ws.accept();
  const got = new Promise((r) => ws.addEventListener('message', (e) => r(e.data)));
  ws.send('x');
  const m = await got;
  ws.close(1000, '');
  return new Response('101 header=' + JSON.stringify(res.headers.get('sec-websocket-extensions')) + ' ws.extensions=' + JSON.stringify(ws.extensions) + ' | server: ' + m);
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0 }));
const base = String(await mf.ready);
const text = async (path) => (await fetch(base + path.replace(/^\//, ''))).text();
const count = async (n, path) => {
  const out = {};
  for (let i = 0; i < n; i++) {
    const t = await text(path);
    out[t] = (out[t] ?? 0) + 1;
  }
  return out;
};
const echo = encodeURIComponent(`http://127.0.0.1:${off.address().port}`);
console.log('1. close(1000) then wait, 150 rounds:', await count(150, `/events?first=still&url=${echo}`));
console.log('1. close(1000), a busy step of 20 ms, then wait, 40 rounds:', await count(40, `/events?first=still&busy=1&url=${echo}`));
console.log('2. the server drops the connection (terminate):', await count(3, `/events?first=drop&url=${echo}`));
console.log('2. the server sends a frame with RSV bits:', await count(3, `/events?first=rsv&url=${echo}`));
for (const [name, s] of [['permessage-deflate on', on], ['permessage-deflate off', off]]) {
  for (const offer of ['', 'permessage-deflate', 'permessage-deflate; client_max_window_bits', 'x-foo']) {
    console.log(`3. server ${name}, offer ${JSON.stringify(offer)}:`, await text(`/ext?url=${encodeURIComponent(`http://127.0.0.1:${s.address().port}`)}&offer=${encodeURIComponent(offer)}`));
  }
}
const c = new W.WebSocket(base.replace('http', 'ws') + 'pair', { perMessageDeflate: true });
await new Promise((r) => c.once('open', r));
c.send('x');
const m = String(await new Promise((r) => c.once('message', r)));
console.log(`3. a Node client that offers permessage-deflate to a WebSocketPair: the client got ${JSON.stringify(c.extensions)}; ${m}`);
c.close();
await mf.dispose();
on.close();
off.close();
