// WebSockets (MODULES.md 12.1, 12.2, PLAN.md 8f part 3): routes of conformance/WebSocketRoutes.roc. The class `Room` on
// a local SQLite-backed Durable Object (the hibernation API), a Worker that answers each message, and clients of a local
// WebSocket echo server (the `ws` package of Miniflare). The clients of the checks are WebSockets of Node (`WebSocket`).
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { answer, eq, ok } from '../assert.mjs';

export const options = { durableObjects: { ROOMS: { className: 'Room', useSQLite: true } } };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let echo = null;
// The echo server: a text "info" gives the protocol and the header `x-test` of the upgrade, "give json" gives
// `{"n":5}`, "delay <ms> <text>" gives "echo <text>" after <ms>, each other text "echo <text>", bytes come back.
function echoServer(t) {
  if (echo) return echo;
  const { WebSocketServer } = createRequire(import.meta.url)(join(dirname(t.mfDir), 'ws'));
  const wss = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  wss.on('connection', (ws, req) => ws.on('message', (m, binary) => {
    if (binary) return ws.send(m);
    const text = m.toString();
    const d = /^delay (\d+) (.*)$/.exec(text);
    if (text === 'info') ws.send(`proto=${ws.protocol} x-test=${req.headers['x-test']}`);
    else if (text === 'give json') ws.send('{"n":5}');
    else if (d) setTimeout(() => ws.send(`echo ${d[2]}`), Number(d[1]));
    else ws.send(`echo ${text}`);
  }));
  echo = new Promise((r) => wss.once('listening', () => r(`ws://127.0.0.1:${wss.address().port}`)));
  return echo;
}

// A client of Node: `next()` gives the next message (text, or the bytes as an array), or throws after `ms`.
export function client(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const got = [];
    const waiters = [];
    const closed = new Promise((r) => ws.addEventListener('close', (e) => r({ code: e.code, reason: e.reason })));
    ws.addEventListener('message', (e) => {
      const v = typeof e.data === 'string' ? e.data : [...new Uint8Array(e.data)];
      const w = waiters.shift();
      if (w) w(v);
      else got.push(v);
    });
    ws.addEventListener('open', () => resolve({
      ws,
      closed,
      send: (v) => ws.send(v),
      next: (ms = 3000) => (got.length ? Promise.resolve(got.shift()) : new Promise((r, j) => {
        const timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(f), 1);
          j(new Error(`no message in ${ms} ms`));
        }, ms);
        const f = (v) => (clearTimeout(timer), r(v));
        waiters.push(f);
      })),
      // The messages that came and that no `next` took.
      pending: () => got.slice(),
      close: (code, reason) => (ws.close(code, reason), closed),
    }));
    ws.addEventListener('error', () => reject(new Error(`the WebSocket to ${url} failed`)));
  });
}
const wsUrl = (base, path) => base.replace(/^http/, 'ws') + path;
const room = (t, name, user) => client(wsUrl(t.url, `/websocket/room/${name}?user=${user}`));
const logOf = (t, msg) => t.logs.filter((l) => String(l.message).includes(`"msg":"${msg}"`)).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{'))));

export const checks = [
  ['websocket a request with no Upgrade gets 426 from the Worker and NotUpgrade from accept!', async (t) => {
    const r = await t.get('/websocket/room/r0?user=a');
    eq(r.status, 426, 'the status of the Worker');
    answer(await t.get('/websocket/plain'), 'Err(NotUpgrade)');
    answer(await t.get('/websocket/room_admin/r0?op=plain'), 'Err(NotUpgrade)');
  }],
  ['websocket the Worker gives the upgrade to the object with fetch!, and the client gets the 101 of the object', async (t) => {
    const a = await room(t, 'r1', 'a');
    a.send('info');
    eq(await a.next(), 'user=a starts=1 events=1 tags=room,a auto=False peers=1 tagged=1', 'info');
    await a.close(1000, 'done');
  }],
  ['websocket two clients in one room: a message of one reaches the other and not the sender', async (t) => {
    const a = await room(t, 'r2', 'a');
    const b = await room(t, 'r2', 'b');
    a.send('hello');
    eq(await b.next(), 'a: hello', 'b got');
    a.send('info');
    eq(await a.next(), 'user=a starts=1 events=2 tags=room,a auto=False peers=2 tagged=1', 'the first message of a (not its own hello)');
    b.send(new Uint8Array([1, 2, 3]));
    eq(JSON.stringify(await b.next()), '[3,2,1]', 'bytes');
    b.send('json');
    eq(await b.next(), '{"n":4,"user":"b"}', 'send_json!');
    // `send_json!` of a NaN is BadData: no frame, so the next frame is the reply of `send!`.
    b.send('json_nan');
    ok((await b.next()).startsWith('bad=Err(Infra(BadData("'), 'Object.Socket send_json! of a NaN');
    await a.close(1000, 'a leaves');
    await b.close(4001, 'b leaves');
  }],
  // Object.Self.broadcast!, broadcast_with! (MODULES.md 12.1): the count of sends that succeed. The sender is in the
  // count and gets the message too, before its own "sent=N" line.
  ['websocket broadcast!: 3 sockets give sent=3 and each gets the message once', async (t) => {
    const a = await room(t, 'bc1', 'a');
    const b = await room(t, 'bc1', 'b');
    const c = await room(t, 'bc1', 'c');
    // Wait until the object knows the 3 sockets.
    c.send('info');
    ok((await c.next()).includes('peers=3'), 'peers=3');
    a.send('bcast');
    eq(await a.next(), 'all from a', 'a gets the message');
    eq(await a.next(), 'sent=3', 'the count');
    eq(await b.next(), 'all from a', 'b gets the message');
    eq(await c.next(), 'all from a', 'c gets the message');
    await sleep(200);
    eq(JSON.stringify([a.pending(), b.pending(), c.pending()]), '[[],[],[]]', 'no second copy');
    await Promise.all([a.close(1000, 'x'), b.close(1000, 'x'), c.close(1000, 'x')]);
  }],
  ['websocket broadcast_with!: only the sockets with the tag get the message', async (t) => {
    const a1 = await room(t, 'bc2', 'a');
    const a2 = await room(t, 'bc2', 'a');
    const b = await room(t, 'bc2', 'b');
    b.send('info');
    ok((await b.next()).includes('peers=3'), 'peers=3');
    a1.send('bcast_tag');
    eq(await a1.next(), 'tag from a', 'a1 gets the message');
    eq(await a1.next(), 'sent=2', 'the count of the tag a');
    eq(await a2.next(), 'tag from a', 'a2 gets the message');
    await sleep(200);
    eq(JSON.stringify([a1.pending(), a2.pending(), b.pending()]), '[[],[],[]]', 'b got nothing, nobody got a second copy');
    // The other tag: one socket.
    b.send('bcast_tag');
    eq(await b.next(), 'tag from b', 'b gets its message');
    eq(await b.next(), 'sent=1', 'the count of the tag b');
    await sleep(200);
    eq(JSON.stringify([a1.pending(), a2.pending()]), '[[],[]]', 'the sockets a got nothing');
    await Promise.all([a1.close(1000, 'x'), a2.close(1000, 'x'), b.close(1000, 'x')]);
  }],
  // N11: `broadcast!` gives `{}` and reaches every socket, `broadcast_json!` sends the JSON text.
  ['websocket broadcast!, broadcast_json!: all sockets get the message (the JSON text for the second), the result is {} and Ok({})', async (t) => {
    const a = await room(t, 'bc5', 'a');
    const b = await room(t, 'bc5', 'b');
    const c = await room(t, 'bc5', 'c');
    c.send('info');
    ok((await c.next()).includes('peers=3'), 'peers=3');
    a.send('bcast_plain');
    eq(await a.next(), 'plain from a', 'a gets the message');
    eq(await a.next(), 'done={}', 'broadcast! gives {}');
    eq(await b.next(), 'plain from a', 'b gets the message');
    eq(await c.next(), 'plain from a', 'c gets the message');
    a.send('bcast_json');
    eq(await a.next(), '{"from":"a"}', 'a gets the JSON text');
    eq(await a.next(), 'done=Ok({})', 'broadcast_json! gives Ok({})');
    eq(await b.next(), '{"from":"a"}', 'b gets the JSON text');
    eq(await c.next(), '{"from":"a"}', 'c gets the JSON text');
    await sleep(200);
    eq(JSON.stringify([a.pending(), b.pending(), c.pending()]), '[[],[],[]]', 'no second copy');
    await Promise.all([a.close(1000, 'x'), b.close(1000, 'x'), c.close(1000, 'x')]);
  }],
  ['websocket broadcast_json_with!: the count, and only the sockets with the tag get the JSON text', async (t) => {
    const a1 = await room(t, 'bc6', 'a');
    const a2 = await room(t, 'bc6', 'a');
    const b = await room(t, 'bc6', 'b');
    b.send('info');
    ok((await b.next()).includes('peers=3'), 'peers=3');
    a1.send('bcast_json_tag');
    eq(await a1.next(), '{"from":"a"}', 'a1 gets the JSON text');
    eq(await a1.next(), 'sent=Ok(2)', 'the count of the tag a');
    eq(await a2.next(), '{"from":"a"}', 'a2 gets the JSON text');
    await sleep(200);
    eq(JSON.stringify([a1.pending(), a2.pending(), b.pending()]), '[[],[],[]]', 'b got nothing, nobody got a second copy');
    await Promise.all([a1.close(1000, 'x'), a2.close(1000, 'x'), b.close(1000, 'x')]);
  }],
  // A NaN in an F64 is not JSON: `Err(Infra(BadData))` and no socket gets a frame (the next frame of `a` is the reply of `send!`).
  ['websocket broadcast_json!, broadcast_json_with!: a NaN is Err(Infra(BadData)) and no socket gets anything', async (t) => {
    const a = await room(t, 'bc7', 'a');
    const b = await room(t, 'bc7', 'b');
    b.send('info');
    ok((await b.next()).includes('peers=2'), 'peers=2');
    a.send('bcast_json_nan');
    const reply = await a.next();
    ok(/^one=Err\(Infra\(BadData\(".+"\)\)\) two=Err\(Infra\(BadData\(".+"\)\)\)$/.test(reply), `the reply of a: ${reply}`);
    await sleep(200);
    eq(JSON.stringify([a.pending(), b.pending()]), '[[],[]]', 'no socket got a frame');
    await Promise.all([a.close(1000, 'x'), b.close(1000, 'x')]);
  }],
  ['websocket broadcast!: after a close the count drops', async (t) => {
    const a = await room(t, 'bc3', 'a');
    const b = await room(t, 'bc3', 'b');
    const c = await room(t, 'bc3', 'c');
    a.send('bcast');
    eq(await a.next(), 'all from a', 'first message');
    eq(await a.next(), 'sent=3', 'before the close');
    await c.close(1000, 'c leaves');
    // The object sees the close after a short time: wait for peers=2.
    let peers = '';
    for (let i = 0; i < 50 && !peers.includes('peers=2'); i++) {
      await sleep(50);
      a.send('info');
      peers = await a.next();
    }
    ok(peers.includes('peers=2'), `the object still has 3 sockets: ${peers}`);
    a.send('bcast');
    eq(await a.next(), 'all from a', 'second message');
    eq(await a.next(), 'sent=2', 'after the close');
    await Promise.all([a.close(1000, 'x'), b.close(1000, 'x')]);
  }],
  // A socket that the object closed is still listed, and its `send!` is `Err(Closed)`: the count has only the sends that work.
  ['websocket broadcast!: a socket that is closed but still listed is not in the count', async (t) => {
    const a = await room(t, 'bc4', 'a');
    const b = await room(t, 'bc4', 'b');
    const v = await room(t, 'bc4', 'victim');
    v.send('info');
    ok((await v.next()).includes('peers=3'), 'peers=3');
    a.send('bcast_closed');
    eq(await a.next(), 'closed from a', 'a gets the message');
    eq(await a.next(), 'sent=2', 'the count has no closed socket');
    eq(await b.next(), 'closed from a', 'b gets the message');
    eq(JSON.stringify((await v.closed).code), '1000', 'the victim is closed');
    await Promise.all([a.close(1000, 'x'), b.close(1000, 'x')]);
  }],
  ['websocket web_socket_close!: the code and the reason of the close of the client', async (t) => {
    for (let i = 0; i < 50 && !logOf(t, 'room close').some((l) => l.code === 4001); i++) await sleep(50);
    const l = logOf(t, 'room close').find((x) => x.code === 4001);
    ok(l && l.reason === 'b leaves' && l.clean === true, `the log: ${JSON.stringify(logOf(t, 'room close'))}`);
    return JSON.stringify(l);
  }],
  ['websocket hibernation: the object leaves memory, and the next message reads the attachment of its socket', async (t) => {
    const a = await room(t, 'r3', 'a');
    a.send('info');
    eq(await a.next(), 'user=a starts=1 events=1 tags=room,a auto=False peers=1 tagged=1', 'before');
    await t.mf.unsafeEvictDurableObject('', 'Room', { name: 'r3', webSockets: 'hibernate' });
    a.send('info');
    eq(await a.next(), 'user=a starts=2 events=2 tags=room,a auto=False peers=1 tagged=1', 'after the eviction (a new constructor: starts=2)');
    await a.close(1000, 'done');
  }],
  ['websocket an auto response answers ping with no event', async (t) => {
    const a = await room(t, 'r4', 'a');
    answer(await t.get('/websocket/room_admin/r4?op=auto'), 'Ok({})');
    a.send('ping');
    eq(await a.next(), 'pong', 'the auto response');
    a.send('info');
    eq(await a.next(), 'user=a starts=1 events=1 tags=room,a auto=True peers=1 tagged=1', 'no event for ping, and auto_response_ms!');
    answer(await t.get('/websocket/room_admin/r4?op=noauto'), 'cleared');
    a.send('ping');
    a.send('info');
    eq(await a.next(), 'user=a starts=1 events=3 tags=room,a auto=True peers=1 tagged=1', 'after clear_auto_response!: ping is an event');
    await a.close(1000, 'done');
  }],
  ['websocket accept_with! of 11 tags is TooLarge', async (t) => answer(await t.get('/websocket/room_admin/r5?op=tags'), 'Err(TooLarge)')],
  ['websocket a Worker: accept!, respond!, receive! until the close', async (t) => {
    const c = await client(wsUrl(t.url, '/websocket/echo'));
    c.send('a');
    eq(await c.next(), 'echo a', 'text');
    c.send(new Uint8Array([0, 255]));
    eq(JSON.stringify(await c.next()), '[0,255]', 'bytes');
    c.send('close');
    const closed = await c.closed;
    eq(`${closed.code} ${closed.reason}`, '1000 bye', 'the close of the Worker');
    for (let i = 0; i < 50 && !logOf(t, 'echo closed').length; i++) await sleep(50);
    const l = logOf(t, 'echo closed')[0];
    ok(l && l.code === 1000, `receive! after the close: ${JSON.stringify(l)}`);
    return JSON.stringify(l);
  }],
  ['websocket connect! to a WebSocket echo server sends and receives one message', async (t) => {
    const url = await echoServer(t);
    answer(await t.get(`/websocket/client?url=${encodeURIComponent(url)}`), 'sent=Ok({}) got=Ok(Text("echo hi"))');
    answer(await t.get(`/websocket/client?url=${encodeURIComponent(url.replace('ws:', 'http:'))}`), 'sent=Ok({}) got=Ok(Text("echo hi"))');
  }],
  ['websocket connect (Io twin), receive (Io twin)', async (t) =>
    answer(await t.get(`/websocket/client_io?url=${encodeURIComponent(await echoServer(t))}`), 'got=Ok(Text("echo twin"))')],
  ['websocket connect_with!: protocols and headers, send_json!, Message.json, a bytes frame', async (t) =>
    answer(await t.get(`/websocket/client_with?url=${encodeURIComponent(await echoServer(t))}`), 'info=Ok(Text("proto=chat x-test=yes")) json=Ok(Text("echo {\\"n\\":5}")) parsed=Ok({ n: 5 }) bytes=Ok(Bytes([0, 1, 255]))')],
  ['websocket connect! to a server that answers 200 gives NotUpgrade (OP7)', async (t) =>
    answer(await t.get(`/websocket/client?url=${encodeURIComponent(`${t.server}/hello`)}`), 'Err NotUpgrade')],
  ['websocket Io.timeout: receive().timeout(50) is TimedOut, the next one gets the message at 100 ms', async (t) =>
    answer(await t.get(`/websocket/timeout?url=${encodeURIComponent(await echoServer(t))}`), 'first=Err(Infra(TimedOut)) next=Ok(Text("echo m"))')],
  ['websocket Io.race! of receive and Time.sleep(50), the message at 100 ms: the sleep wins, the next receive! gets it', async (t) =>
    answer(await t.get(`/websocket/race?url=${encodeURIComponent(await echoServer(t))}`), 'first=1 Ok(TimedOut) next=Ok(Got(Text("echo m")))')],
  ['websocket OP8 in the same turn: a receive that loses to a branch with no wait gives its message back, the next receive gets it', async (t) =>
    answer(await t.get(`/websocket/race_ready?url=${encodeURIComponent(await echoServer(t))}`), 'first=1 second=0 next=Ok(Got(Text("echo m")))')],
  // API.md 10.2 with smaller deadlines (a second Miniflare): `afterRespondMs` 1.5 s, `taskDeadlineMs` 1 s. A request
  // starts the sweep of the task table (PLAN.md 3b).
  ['websocket a 101 response keeps the task: the socket answers after afterRespondMs, and a wait on a socket has no deadline', async (t) => {
    const entry = t.entry.replace('initMs: 1000 }', 'initMs: 1000, afterRespondMs: 1500, taskDeadlineMs: 1000 }');
    ok(entry !== t.entry, 'no makeHandler options to change');
    const mf = t.start({ durableObjects: options.durableObjects, handleStructuredLogs: () => {} }, entry);
    try {
      const base = (await mf.ready).href.replace(/\/$/, '');
      const c = await client(wsUrl(base, '/websocket/echo'));
      c.send('a');
      eq(await c.next(), 'echo a', 'first');
      // A wait that is not on the socket (`Time.sleep!` of 3 s), with a sweep at 2 s: the 101 response is open while
      // its socket is open, so the task has no deadline.
      c.send('sleep 3000');
      await sleep(2000);
      await (await mf.dispatchFetch(`${base}/time/now`)).text();
      eq(await c.next(3000), 'slept', 'a sleep of 3 s after respond!, a sweep at 2 s');
      // A wait on the socket of 2 s, and a sweep.
      await sleep(2000);
      await (await mf.dispatchFetch(`${base}/time/now`)).text();
      c.send('late');
      eq(await c.next(2000), 'echo late', 'after 2 s and a sweep');
      await c.close(1000, 'done');
      const url = await echoServer(t);
      const [slow] = await Promise.all([
        mf.dispatchFetch(`${base}/websocket/slow?url=${encodeURIComponent(url)}`).then(async (r) => `${r.status} ${await r.text()}`),
        sleep(1500).then(() => mf.dispatchFetch(`${base}/time/now`)).then((r) => r.text()),
      ]);
      eq(slow, '200 Ok(Text("echo s"))', 'a receive! of 2 s, deadline of a wait 1 s');
    } finally {
      await mf.dispose();
    }
  }],
  ['websocket Io.timeout that does not fire: Ok at once, the sleep is aborted', async (t) => {
    const r = await t.get(`/websocket/timeout_ok?url=${encodeURIComponent(await echoServer(t))}`);
    answer(r, 'first=Ok(Text("echo m"))');
    ok(r.ms < 1500, `${r.ms} ms: the sleep of 5 s is aborted`);
  }],
  ['websocket send_json! of a NaN is BadData and no frame goes out', async (t) => {
    const r = await t.get(`/websocket/send_json_nan?url=${encodeURIComponent(await echoServer(t))}`);
    ok(r.status === 200 && r.body.startsWith('bad=Err(Infra(BadData("'), `got ${r.body}`);
    ok(r.body.endsWith(' good=Ok({}) first=Ok(Text("echo {\\"r\\":0.5}")) second=Ok(Text("echo after"))'), `got ${r.body}`);
  }],
  // The typed attachment `Object.Attachment` (MODULES.md 12.1).
  ['websocket Attachment: NotFound before set!, a record round trip, and a read as another type is BadData', async (t) => {
    const a = await client(wsUrl(t.url, '/websocket/room/ra?user=a&noattach=1'));
    a.send('att_before');
    eq(await a.next(), 'Err(NotFound)', 'before set!');
    a.send('att_round');
    eq(await a.next(), 'set=Ok({}) same=True', 'a record of Str, U64 of 2^60, List, Bool, I64');
    a.send('att_wrong');
    const wrong = await a.next();
    ok(wrong.startsWith('Err(Infra(BadData("the attachment count: ') && !wrong.includes('Ok('), `read as U64: ${wrong}`);
    await a.close(1000, 'done');
    // The `user` slot set at the join is read back with the same slot (and as another type: BadData).
    const b = await room(t, 'rb', 'b');
    b.send('att_wrong');
    ok((await b.next()).startsWith('Err(Infra(BadData("the attachment count: '), 'a socket that has a user record, read as U64');
    b.send('info');
    ok((await b.next()).startsWith('user=b '), 'the same slot still reads it');
    await b.close(1000, 'done');
  }],
];
