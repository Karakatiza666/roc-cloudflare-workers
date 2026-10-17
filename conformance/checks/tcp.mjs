// `Tcp` and `Hyperdrive.connect!` (MODULES.md 12.3, 13, PLAN.md 8f part 3): routes of conformance/TcpRoutes.roc and
// HyperdriveRoutes.roc against a local TCP echo server (Miniflare runs `connect` of `cloudflare:sockets` to a local
// address). The Hyperdrive binding `PGECHO` has the echo server as its origin.
import { createServer } from 'node:net';
import { answer, ok } from '../assert.mjs';

// The echo server: each chunk back, "slow" gives "late" after 100 ms, "bye" ends the connection.
const server = createServer((c) => {
  c.on('error', () => {});
  c.on('data', (d) => {
    const text = d.toString();
    if (text === 'slow') setTimeout(() => c.write('late'), 100);
    else if (text === 'bye') c.end();
    else c.write(d);
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
server.unref();
const port = server.address().port;

export const options = { hyperdrives: { PGECHO: `postgres://user:secret@127.0.0.1:${port}/echo` } };

export const checks = [
  ['tcp connect!, write!, read!, close!', async (t) => answer(await t.get(`/tcp/echo?port=${port}`), 'write=Ok({}) read=Ok("hello")')],
  ['tcp connect (Io twin), write (Io twin), read (Io twin), connect_with! tls Off', async (t) =>
    answer(await t.get(`/tcp/echo_io?port=${port}`), 'write=Ok({}) read=Ok("twin") with=Ok([0, 1, 255])')],
  ['tcp connect! to a port with no server is SocketErr', async (t) => {
    const r = await t.get('/tcp/closed_port');
    ok(r.status === 200 && r.body.startsWith('Err(SocketErr('), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  ['tcp read! after the end of the peer is Closed, write! after close! is Closed', async (t) =>
    answer(await t.get(`/tcp/end?port=${port}`), 'read=Err(Closed) write_after_close=Err(Closed)')],
  ['tcp Io.race! of read and Time.sleep(50), the bytes at 100 ms: the sleep wins, the next read gets them', async (t) =>
    answer(await t.get(`/tcp/race?port=${port}`), 'first=1 Ok(TimedOut) next=Ok(Got("late"))')],
  ['tcp OP8 in the same turn: a read that loses to a branch with no wait gives its bytes back, the next read gets them', async (t) =>
    answer(await t.get(`/tcp/race_ready?port=${port}`), 'first=1 second=0 next=Ok(Got("late"))')],
  ['hyperdrive connect!, connect (Io twin): a Tcp socket to the origin of the binding', async (t) =>
    answer(await t.get('/hyperdrive/connect?name=PGECHO'), 'write=Ok({}) read=Ok(Got("hd")) twin: write=Ok({}) read=Ok(Got("hd"))')],
];
