// The facts of local workerd (Miniflare of the global wrangler) for the WebSocket gaps of roc-websocket DESIGN.md 6.3:
// the subprotocol of a client socket and of a 101 response, the throws of send() and close(), readyState, bufferedAmount,
// and the close event of a hibernatable socket after a close of the server.
//   node research/ws-gaps-probe/probe.mjs   (output: research/ws-gaps-probe/out.txt)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const req = createRequire(import.meta.url);
const { Miniflare, convertV4MiniflareOptions } = req(mfDir);
const { WebSocketServer } = req(join(dirname(mfDir), 'ws'));

const script = `
import { DurableObject } from 'cloudflare:workers';
const err = (e) => e.name + ': ' + e.message;
const props = (ws) => ({ protocol: ws.protocol, extensions: ws.extensions, hasBuffered: 'bufferedAmount' in ws, buffered: ws.bufferedAmount, readyState: ws.readyState });
const closeCases = (mk) => {
  const out = {};
  for (const [code, reason] of [[1000, 'ok'], [1001, 'x'], [1005, ''], [1006, ''], [999, ''], [2000, ''], [2999, ''], [3000, ''], [4999, ''], [5000, ''], [1000, 'r'.repeat(123)], [1000, 'r'.repeat(124)], [1000, 'é'.repeat(62)]]) {
    const ws = mk();
    try { ws.close(code, reason); out[code + '/' + reason.length] = 'ok'; } catch (e) { out[code + '/' + reason.length] = err(e); }
  }
  const ws = mk();
  ws.close(1000, 'a');
  try { ws.close(1000, 'b'); out.twice = 'ok'; } catch (e) { out.twice = err(e); }
  out.rsAfterClose = ws.readyState;
  try { ws.send('x'); out.sendAfterClose = 'ok'; } catch (e) { out.sendAfterClose = err(e); }
  const big = mk();
  for (const n of [1 << 20, 33 << 20, 64 << 20]) { try { big.send(new Uint8Array(n)); out['send' + n] = 'ok'; } catch (e) { out['send' + n] = err(e); } }
  const fresh = new WebSocketPair()[1];
  try { fresh.send('x'); out.sendBeforeAccept = 'ok'; } catch (e) { out.sendBeforeAccept = err(e); }
  try { fresh.close(1000, 'x'); out.closeBeforeAccept = 'ok'; } catch (e) { out.closeBeforeAccept = err(e); }
  return out;
};
export class Room extends DurableObject {
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/do/cases') return Response.json(closeCases(() => { const p = new WebSocketPair(); this.ctx.acceptWebSocket(p[1]); return p[1]; }));
    const [c, s] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(s);
    const h = u.searchParams.get('proto');
    return new Response(null, { status: 101, webSocket: c, headers: h ? { 'Sec-WebSocket-Protocol': h } : {} });
  }
  webSocketMessage(ws, msg) {
    if (msg === 'props') return ws.send(JSON.stringify(props(ws)));
    if (msg === 'close-me') { ws.close(4002, 'server'); console.log('DO after close() readyState=' + ws.readyState); return; }
    if (msg === 'send-after-close') { ws.close(4003, 's'); try { ws.send('x'); console.log('DO send after close ok'); } catch (e) { console.log('DO send after close ' + err(e)); } return; }
  }
  webSocketClose(ws, code, reason, wasClean) {
    console.log('DO webSocketClose code=' + code + ' reason=' + reason + ' clean=' + wasClean + ' readyState=' + ws.readyState);
    try { ws.close(code, reason); console.log('DO echo close ok'); } catch (e) { console.log('DO echo close ' + err(e)); }
  }
}
export default {
  async fetch(req, env, ctx) {
    const u = new URL(req.url);
    const q = (k) => u.searchParams.get(k);
    if (u.pathname.startsWith('/do')) return env.ROOM.getByName('r' + (q('n') ?? '')).fetch(req);
    if (u.pathname === '/cases') return Response.json(closeCases(() => { const s = new WebSocketPair()[1]; s.accept(); return s; }));
    if (u.pathname === '/pair') {
      const [c, s] = Object.values(new WebSocketPair());
      s.accept();
      s.addEventListener('message', (e) => {
        if (e.data === 'props') s.send(JSON.stringify(props(s)));
        else if (e.data === 'close-me') { s.close(4002, 'server'); console.log('pair after close() readyState=' + s.readyState); }
      });
      s.addEventListener('close', (e) => console.log('pair close code=' + e.code + ' reason=' + e.reason + ' clean=' + e.wasClean + ' readyState=' + s.readyState));
      const h = q('proto');
      return new Response(null, { status: 101, webSocket: c, headers: h ? { 'Sec-WebSocket-Protocol': h } : {} });
    }
    if (u.pathname === '/client') {
      const out = {};
      const headers = { Upgrade: 'websocket' };
      if (q('offer')) headers['Sec-WebSocket-Protocol'] = q('offer');
      const res = await fetch(q('url'), { headers });
      out.status = res.status; out.resProto = res.headers.get('sec-websocket-protocol');
      const ws = res.webSocket;
      out.before = props(ws);
      ws.accept();
      out.after = props(ws);
      const closed = new Promise((r) => ws.addEventListener('close', (e) => r({ code: e.code, reason: e.reason, clean: e.wasClean, rs: ws.readyState })));
      if (q('peerclose')) { ws.send('close please'); out.peerClose = await closed; }
      else { ws.close(1000, 'bye'); out.ourClose = await Promise.race([closed, new Promise((r) => setTimeout(() => r('no close event in 2 s'), 2000))]); }
      return Response.json(out);
    }
    return new Response('no route', { status: 404 });
  },
};
`;

const wss = new WebSocketServer({ port: 0, host: '127.0.0.1', handleProtocols: (set) => (set.has('v2') ? 'v2' : false) });
await new Promise((r) => wss.once('listening', r));
wss.on('connection', (ws) => ws.on('message', (m) => { if (m.toString() === 'close please') ws.close(4005, 'peer bye'); else ws.send('echo ' + m); }));
const wsUrl = `http://127.0.0.1:${wss.address().port}`;
const logs = [];
const mf = new Miniflare(convertV4MiniflareOptions({
  modules: true, script, compatibilityDate: '2026-10-01', compatibilityFlags: ['enable_request_signal'], port: 0,
  durableObjects: { ROOM: { className: 'Room', useSQLite: true } },
  handleStructuredLogs: (l) => logs.push(String(l.message)),
}));
const base = (await mf.ready).href.replace(/\/$/, '');
const show = (k, v) => console.log(`${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const open = (p, protocols) => new Promise((resolve, reject) => {
  const ws = new WebSocket(base.replace('http', 'ws') + p, protocols);
  const msgs = [];
  ws.onmessage = (e) => msgs.push(e.data);
  const closed = new Promise((r) => ws.addEventListener('close', (e) => r({ code: e.code, reason: e.reason, clean: e.wasClean })));
  ws.onopen = () => resolve({ ws, msgs, closed });
  ws.onerror = (e) => reject(new Error('ws error ' + (e.message ?? 'x')));
});
const next = async (c, n) => { for (let i = 0; i < 100 && c.msgs.length < n; i++) await sleep(20); return c.msgs[n - 1]; };
try {
  show('worker close/send cases', await (await mf.dispatchFetch(base + '/cases')).json());
  show('DO close/send cases', await (await mf.dispatchFetch(base + '/do/cases?n=c')).json());
  for (const [path, label] of [['/pair', 'pair'], ['/do', 'DO']]) {
    try {
      const a = await open(`${path}?proto=v2&n=p`, ['chat', 'v2']);
      a.ws.send('props');
      show(`${label} 101 with Sec-WebSocket-Protocol v2: Node client protocol`, a.ws.protocol);
      show(`${label} server socket props`, await next(a, 1));
      a.ws.close(1000, 'x');
    } catch (e) { show(`${label} 101 with protocol v2`, String(e)); }
    try {
      const a = await open(`${path}?proto=zzz&n=q`, ['chat', 'v2']);
      show(`${label} 101 with a protocol not offered: Node client`, `opened, protocol=${a.ws.protocol}`);
      a.ws.close(1000, 'x');
    } catch (e) { show(`${label} 101 with a protocol not offered`, String(e)); }
    try {
      const a = await open(`${path}?n=s`, ['chat', 'v2']);
      show(`${label} 101 with no protocol header, client offered: Node client`, `opened, protocol=${JSON.stringify(a.ws.protocol)}`);
      a.ws.close(1000, 'x');
    } catch (e) { show(`${label} 101 with no protocol header`, String(e)); }
    // A close of the server.
    const b = await open(`${path}?n=c${label}`);
    b.ws.send('close-me');
    show(`${label} close of the server: Node client got`, await b.closed);
    await sleep(300);
    // A close of the client.
    const c = await open(`${path}?n=d${label}`);
    c.ws.close(4001, 'client');
    show(`${label} close of the client: Node client got`, await c.closed);
    await sleep(300);
  }
  // Hibernation between the close of the server and the reply: not timed here; the eviction drops JS memory.
  const e = await open('/do?n=ev');
  await mf.unsafeEvictDurableObject('', 'Room', { name: 'rev', webSockets: 'hibernate' });
  e.ws.send('close-me');
  show('DO (after an eviction) close of the server: Node client got', await e.closed);
  await sleep(300);
  const f = await open('/do?n=sa');
  f.ws.send('send-after-close');
  await f.closed; await sleep(300);
  show('client fetch, offer chat,v2 (server picks v2)', await (await mf.dispatchFetch(`${base}/client?url=${encodeURIComponent(wsUrl)}&offer=chat,v2`)).json());
  show('client fetch, no offer', await (await mf.dispatchFetch(`${base}/client?url=${encodeURIComponent(wsUrl)}`)).json());
  show('client fetch, peer closes', await (await mf.dispatchFetch(`${base}/client?url=${encodeURIComponent(wsUrl)}&peerclose=1`)).json());
  await sleep(300);
  for (const l of logs) console.log('log: ' + l);
} finally {
  await mf.dispose();
  wss.close();
}
