// PLAN.md 11c: the echo Worker of the edge run (`rocplat-test-echo`). It has the same routes as the local server of
// conformance/run.mjs: `/hello` (text), `/ten` (10 bytes), `/slow` (answers after 2 s), `/broken` (6 MiB, then the body
// errors), `/big?n=` and `/drip?parts=&size=&gap=` (byte i is i % 251), `/echo` (the method, the header `x-test` and the
// body), `/echo_json`, the Cloudflare error pages `/cf530`, `/cf403`, `/cf200`, `/cf64`, `/cflong`, `/status/<n>` (that
// status, no body). Also `/hang` (answers after 10 min, a host that does not answer) and `/ws`: the WebSocket echo server
// of conformance/checks/websocket.mjs (`t.wsEcho` of edge/run-edge.mjs).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const PAT = Uint8Array.from({ length: 65536 + 251 }, (_, i) => i % 251);
const at = (from, n) => (n <= 65536 ? PAT.slice(from % 251, (from % 251) + n) : Uint8Array.from({ length: n }, (_, i) => (from + i) % 251));

// The protocol of `echoServer` of checks/websocket.mjs: "info" gives the protocol and the header `x-test` of the
// upgrade, "give json" gives `{"n":5}`, "delay <ms> <text>" gives "echo <text>" after <ms>, "close me" closes with 4005
// "peer bye", each other text "echo <text>", bytes come back. The first subprotocol that the client asks for.
function wsEcho(req) {
  const asked = (req.headers.get('sec-websocket-protocol') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const [client, server] = Object.values(new WebSocketPair());
  server.accept();
  // Bytes as an ArrayBuffer (with the standard binaryType of the compatibility date, the default is a Blob).
  server.binaryType = 'arraybuffer';
  const proto = asked[0] ?? '';
  server.addEventListener('message', (e) => {
    if (typeof e.data !== 'string') return server.send(e.data);
    const text = e.data;
    const d = /^delay (\d+) (.*)$/.exec(text);
    if (text === 'info') server.send(`proto=${proto} x-test=${req.headers.get('x-test') ?? 'undefined'}`);
    else if (text === 'give json') server.send('{"n":5}');
    else if (text === 'close me') server.close(4005, 'peer bye');
    else if (d) setTimeout(() => server.send(`echo ${d[2]}`), Number(d[1]));
    else server.send(`echo ${text}`);
  });
  server.addEventListener('close', (e) => { try { server.close(e.code === 1005 ? 1000 : e.code, e.reason); } catch {} });
  const headers = proto ? { 'sec-websocket-protocol': proto } : {};
  return new Response(null, { status: 101, webSocket: client, headers });
}

export default {
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    const q = url.searchParams;
    if (path === '/ws' && req.headers.get('upgrade') === 'websocket') return wsEcho(req);
    if (path === '/hello') return new Response('hello');
    if (path === '/ten') return new Response('0123456789');
    if (path === '/slow') return sleep(2000).then(() => new Response('late'));
    if (path === '/hang') return sleep(600_000).then(() => new Response('late'));
    // A content-length of 7 MiB, 6 MiB of bytes, then the body stops with an error: the client sees a broken body.
    // The local server sends no length and breaks the connection. A Worker cannot do that: a stream with no length that
    // errors, and a gzip body with no trailer, are a clean end for the client on the edge (tried 2026-11-11). Only a
    // body shorter than its length gives the client an error, and that body has a known length.
    if (path === '/broken') {
      const { readable, writable } = new FixedLengthStream(7 * 1024 * 1024);
      (async () => {
        const w = writable.getWriter();
        for (let sent = 0; sent < 6 * 1024 * 1024; sent += 65536) await w.write(new Uint8Array(65536).fill(66));
        await sleep(100);
        await w.abort(new Error('broken'));
      })().catch(() => {});
      return new Response(readable);
    }
    if (path === '/big') {
      const n = Number(q.get('n'));
      const { readable, writable } = new FixedLengthStream(n);
      (async () => {
        const w = writable.getWriter();
        for (let sent = 0; sent < n; sent += 65536) await w.write(at(sent, Math.min(65536, n - sent)));
        await w.close();
      })();
      return new Response(readable);
    }
    if (path === '/drip') {
      const parts = Number(q.get('parts')), size = Number(q.get('size')), gap = Number(q.get('gap'));
      let i = 0;
      const body = new ReadableStream({
        async pull(c) {
          if (i > 0) await sleep(gap);
          c.enqueue(at(i * size, size));
          if (++i >= parts) c.close();
        },
      });
      return new Response(body);
    }
    if (path === '/echo_json') return new Response(`${req.method} ${req.headers.get('content-type') ?? '-'} ${await req.text()}`);
    if (path === '/echo') return new Response(`${req.method} ${req.headers.get('x-test') ?? '-'} ${await req.text()}`);
    if (path === '/cf530') return new Response('error code: 1016', { status: 530 });
    if (path === '/cf403') return new Response('error code: 1003', { status: 403 });
    if (path === '/cf200') return new Response('error code: 1003');
    if (path === '/cf64') return new Response(`error code: 1003${' '.repeat(48)}`, { status: 403 });
    if (path === '/cflong') return new Response(`error code: 1003${' '.repeat(60)}`, { status: 403 });
    if (path.startsWith('/status/')) return new Response(null, { status: Number(path.slice(8)) });
    return new Response('no route', { status: 404 });
  },
};
