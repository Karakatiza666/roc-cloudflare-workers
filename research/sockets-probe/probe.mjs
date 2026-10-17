// The facts of local WebSockets and TCP sockets (Miniflare 5) that PLAN.md 8f, part 3 needs: the hibernation API of a
// Durable Object (identity of the sockets of getWebSockets, attachments after an eviction, auto responses, tags), a
// WebSocketPair in a Worker, a client socket (fetch with Upgrade: a ws:// URL, a server that answers 200), `connect` of
// `cloudflare:sockets` to a local TCP server, and `connect` of a Hyperdrive binding.
//   node research/sockets-probe/probe.mjs   (Miniflare of the global wrangler)
import { createRequire } from 'node:module';
import { createServer as tcpServer } from 'node:net';
import { createServer as httpServer } from 'node:http';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const req = createRequire(import.meta.url);
const { Miniflare, convertV4MiniflareOptions } = req(mfDir);
const { WebSocketServer } = req(join(dirname(mfDir), 'ws'));

const script = `
import { DurableObject } from 'cloudflare:workers';
import { connect } from 'cloudflare:sockets';
const err = (e) => e.name + ': ' + e.message;
const kind = (v) => v === null ? 'null' : v === undefined ? 'undefined' : Array.isArray(v) ? 'Array' : v instanceof ArrayBuffer ? 'ArrayBuffer' : typeof v === 'object' ? (Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto') : typeof v;
let starts = 0;
export class Room extends DurableObject {
  constructor(ctx, env) { super(ctx, env); starts++; }
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/auto') { this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong')); return new Response('auto set'); }
    if (u.pathname === '/count') return new Response(String(this.ctx.getWebSockets().length));
    const pair = new WebSocketPair();
    const [c, s] = Object.values(pair);
    this.ctx.acceptWebSocket(s, ['t1', u.searchParams.get('user') ?? 'anon']);
    s.serializeAttachment(new Uint8Array([1, 2, 3]));
    let tooMany;
    try { const p2 = new WebSocketPair(); this.ctx.acceptWebSocket(p2[1], Array.from({ length: 11 }, (_, i) => 't' + i)); tooMany = 'ok'; } catch (e) { tooMany = err(e); }
    let bigAtt;
    try { s.serializeAttachment(new Uint8Array(20000)); bigAtt = 'ok'; } catch (e) { bigAtt = err(e); }
    s.serializeAttachment(new Uint8Array([1, 2, 3]));
    return new Response(null, { status: 101, webSocket: c, headers: { 'x-too-many': tooMany, 'x-big-att': bigAtt } });
  }
  webSocketMessage(ws, msg) {
    const all = this.ctx.getWebSockets();
    const att = ws.deserializeAttachment();
    let autoTs;
    try { autoTs = kind(this.ctx.getWebSocketAutoResponseTimestamp(ws)) + ' ' + String(this.ctx.getWebSocketAutoResponseTimestamp(ws)); } catch (e) { autoTs = err(e); }
    ws.send(JSON.stringify({ same: all.includes(ws), n: all.length, byTag: this.ctx.getWebSockets('t1').includes(ws), att: kind(att) + ' ' + (att instanceof Uint8Array ? [...att] : att), starts, tags: this.ctx.getTags(ws), autoTs, msgKind: kind(msg), msg: typeof msg === 'string' ? msg : [...new Uint8Array(msg)] }));
  }
  webSocketClose(ws, code, reason, wasClean) { console.log('close', code, reason, wasClean); }
}
export default {
  async fetch(req, env, ctx) {
    const u = new URL(req.url);
    const q = (k) => u.searchParams.get(k);
    if (u.pathname === '/room' || u.pathname === '/auto' || u.pathname === '/count') return env.ROOM.getByName('r').fetch(req);
    if (u.pathname === '/pair') {
      const [c, s] = Object.values(new WebSocketPair());
      s.accept();
      s.addEventListener('message', (e) => s.send('echo ' + e.data));
      s.addEventListener('close', (e) => console.log('pair close', e.code, e.reason, e.wasClean));
      return new Response(null, { status: 101, webSocket: c });
    }
    if (u.pathname === '/client') {
      const out = {};
      let res;
      try { res = await fetch(q('url'), { headers: { Upgrade: 'websocket' } }); } catch (e) { return new Response('fetch threw ' + err(e)); }
      out.status = res.status; out.ws = kind(res.webSocket);
      if (!res.webSocket) return Response.json(out);
      const ws = res.webSocket;
      ws.accept();
      const got = new Promise((r) => ws.addEventListener('message', (e) => r(e.data)));
      ws.send('hi');
      out.got = await got;
      ws.close(1000, 'bye');
      try { ws.send('late'); out.sendAfterClose = 'ok'; } catch (e) { out.sendAfterClose = err(e); }
      return Response.json(out);
    }
    if (u.pathname === '/tcp') {
      const out = {};
      try {
        const s = connect({ hostname: '127.0.0.1', port: Number(q('port')) });
        out.socket = kind(s); out.keys = Object.getOwnPropertyNames(Object.getPrototypeOf(s));
        out.opened = await s.opened;
        const w = s.writable.getWriter();
        await w.write(new TextEncoder().encode('hello'));
        const r = s.readable.getReader();
        const { value, done } = await r.read();
        out.read = done ? 'done' : new TextDecoder().decode(value);
        await w.close();
        const second = await r.read();
        out.afterClose = second.done ? 'done' : 'more';
        await s.close();
      } catch (e) { out.err = err(e); }
      try { const s = connect({ hostname: '127.0.0.1', port: 1 }); await s.opened; out.closedPort = 'opened'; } catch (e) { out.closedPort = err(e); }
      return Response.json(out);
    }
    if (u.pathname === '/hd') {
      const out = { keys: Object.getOwnPropertyNames(Object.getPrototypeOf(env.HD)), cs: env.HD.connectionString, host: env.HD.host, port: env.HD.port };
      try {
        const s = env.HD.connect();
        out.socket = kind(s);
        out.opened = await s.opened;
        const w = s.writable.getWriter();
        await w.write(new TextEncoder().encode('hd hello'));
        const { value } = await s.readable.getReader().read();
        out.read = new TextDecoder().decode(value);
        await s.close();
      } catch (e) { out.err = err(e); }
      return Response.json(out);
    }
    return new Response('no route', { status: 404 });
  },
};
`;

// A TCP echo server, a WebSocket echo server, an HTTP server that answers 200.
const tcp = tcpServer((c) => c.on('data', (d) => c.write(d)));
await new Promise((r) => tcp.listen(0, '127.0.0.1', r));
const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' });
await new Promise((r) => wss.once('listening', r));
wss.on('connection', (ws) => ws.on('message', (m, binary) => ws.send(binary ? m : 'echo ' + m.toString())));
const http = httpServer((q, s) => s.end('plain'));
await new Promise((r) => http.listen(0, '127.0.0.1', r));
const tcpPort = tcp.address().port, wsPort = wss.address().port, httpPort = http.address().port;

const mf = new Miniflare(convertV4MiniflareOptions({
  modules: true, script, compatibilityDate: '2026-10-01', port: 0,
  durableObjects: { ROOM: { className: 'Room', useSQLite: true } },
  hyperdrives: { HD: `postgres://u:p@127.0.0.1:${tcpPort}/db` },
}));
const url = await mf.ready;
const base = url.href.replace(/\/$/, '');
const show = (k, v) => console.log(`${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);
const text = async (p) => (await fetch(base + p)).text();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// A client socket of Node to the worker.
const open = (p) => new Promise((resolve, reject) => {
  const ws = new WebSocket(base.replace('http', 'ws') + p);
  const msgs = [];
  ws.onmessage = (e) => msgs.push(e.data);
  ws.onopen = () => resolve({ ws, msgs });
  ws.onerror = (e) => reject(new Error('ws error ' + e.message));
});
const next = async (c, n) => { for (let i = 0; i < 100 && c.msgs.length < n; i++) await sleep(20); return c.msgs[n - 1]; };
try {
  // Hibernation API.
  const a = await open('/room?user=a');
  const b = await open('/room?user=b');
  a.ws.send('one');
  show('message (identity, attachment, tags)', await next(a, 1));
  const r101 = await mf.dispatchFetch(base + '/room', { headers: { Upgrade: 'websocket' } });
  show('101 headers of the object (11 tags, attachment of 20000 bytes)', { status: r101.status, tooMany: r101.headers.get('x-too-many'), bigAtt: r101.headers.get('x-big-att') });
  await mf.unsafeEvictDurableObject('', 'Room', { name: 'r', webSockets: 'hibernate' }).then(() => show('evict', 'ok'), (e) => show('evict', e.message));
  a.ws.send(new Uint8Array([9, 8]));
  show('message after eviction (starts 2?)', await next(a, 2));
  show('auto', await text('/auto'));
  a.ws.send('ping');
  show('auto response', await next(a, 3));
  a.ws.send('after ping');
  show('message after the auto response (autoTs)', await next(a, 4));
  b.ws.close(1000, 'b leaves');
  await sleep(200);
  show('sockets after a close', await text('/count'));
  a.ws.close();
  // A Worker with a WebSocketPair.
  const p = await open('/pair');
  p.ws.send('x');
  show('pair echo', await next(p, 1));
  p.ws.close(4000, 'done');
  // Clients.
  show('client http://', await text(`/client?url=${encodeURIComponent(`http://127.0.0.1:${wsPort}`)}`));
  show('client ws://', await text(`/client?url=${encodeURIComponent(`ws://127.0.0.1:${wsPort}`)}`));
  show('client 200', await text(`/client?url=${encodeURIComponent(`http://127.0.0.1:${httpPort}`)}`));
  // TCP and Hyperdrive.
  show('tcp', await text(`/tcp?port=${tcpPort}`));
  show('hyperdrive', await text('/hd'));
  await sleep(300);
} finally {
  await mf.dispose();
  tcp.close(); wss.close(); http.close();
}
