// `Tcp` and `Hyperdrive.connect!` (MODULES.md 12.3, 13, PLAN.md 8f part 3): routes of conformance/TcpRoutes.roc and
// HyperdriveRoutes.roc against a local TCP echo server (Miniflare runs `connect` of `cloudflare:sockets` to a local
// address). The Hyperdrive binding `PGECHO` has the echo server as its origin.
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { answer, ok } from '../assert.mjs';
import { makeCert, startServer } from '../starttls-server.mjs';

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

// EP11: the local STARTTLS server (conformance/starttls-server.mjs) with a test certificate. Miniflare has no option for a
// trusted certificate, so the check starts a second Miniflare with `SSL_CERT_FILE` set (workerd trusts that file, not only the
// system store). It is in the check, not at the load: the edge run (`t.start` is MF-ONLY there) never starts it.
async function startTlsLocal(t) {
  const dir = mkdtempSync(join(tmpdir(), 'starttls-'));
  const { cert, key, certFile } = makeCert(dir);
  const { server, port } = await startServer({ cert, key });
  const before = process.env.SSL_CERT_FILE;
  process.env.SSL_CERT_FILE = certFile;
  let mf;
  try {
    mf = t.start();
    await mf.ready;
  } finally {
    if (before === undefined) delete process.env.SSL_CERT_FILE;
    else process.env.SSL_CERT_FILE = before;
  }
  return {
    port,
    mf,
    async stop() {
      await mf.dispose();
      server.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export const checks = [
  ['tcp connect!, write!, read!, close!', async (t) => answer(await t.get(`/tcp/echo?port=${port}`), 'write=Ok({}) read=Ok("hello")')],
  ['tcp connect (Io twin), write (Io twin), read (Io twin), connect_with! tls Off', async (t) =>
    answer(await t.get(`/tcp/echo_io?port=${port}`), 'write=Ok({}) read=Ok("twin") with=Ok([0, 1, 255])')],
  ['tcp connect! to a port with no server is SocketErr', async (t) => {
    const r = await t.get('/tcp/closed_port');
    ok(r.status === 200 && r.body.startsWith('Err(Infra(SocketErr('), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  ['tcp read! after the end of the peer is Closed, write! after close! is Closed', async (t) =>
    answer(await t.get(`/tcp/end?port=${port}`), 'read=Err(Closed) write_after_close=Err(Closed)')],
  ['tcp Io.race! of read and Time.sleep(50), the bytes at 100 ms: the sleep wins, the next read gets them', async (t) =>
    answer(await t.get(`/tcp/race?port=${port}`), 'first=1 Ok(TimedOut) next=Ok(Got("late"))')],
  ['tcp OP8 in the same turn: a read that loses to a branch with no wait gives its bytes back, the next read gets them', async (t) =>
    answer(await t.get(`/tcp/race_ready?port=${port}`), 'first=1 second=0 next=Ok(Got("late"))')],
  // PLAN.md 11c, E47, EP6: a socket of `tls: StartTls` reads and writes before `start_tls!` (the echo server has no TLS). On the
  // edge this hung after the first read (not here: research/starttls/README.md).
  ['tcp connect_with! tls StartTls: write! and read! twice before start_tls!', async (t) =>
    answer(await t.get(`/tcp/starttls_plain?port=${port}`), 'first=Ok("one") second=Ok("two")')],
  ['tcp start_tls! on a socket of tls Off is SocketErr (the option secureTransport)', async (t) => {
    const r = await t.get(`/tcp/start_tls_off?port=${port}`);
    ok(r.status === 200 && r.body.startsWith('Err(Infra(SocketErr(') && r.body.includes("'starttls' for startTls to be used"), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  // EP11: `start_tls!` released neither the reader nor the writer, so `opened` of the new socket never settled. The route
  // has a timeout of 3 s (`TimedOut`), so a bad shim fails this check and does not hang the run.
  ['tcp start_tls! upgrades a socket of tls StartTls: write! and read! over TLS (a local STARTTLS server)', async (t) => {
    const l = await startTlsLocal(t);
    try {
      const res = await l.mf.dispatchFetch(`http://localhost/tcp/starttls_tls?port=${l.port}`);
      const body = await res.text();
      const want = 'banner=Ok("220 localhost ESMTP starttls-probe\r\n") ehlo=Ok("250-localhost\r\n250 STARTTLS\r\n") ready=Ok("220 2.0.0 Ready to start TLS\r\n") secure=Ok("250 localhost secure\r\n")';
      ok(res.status === 200 && body === want, `got ${res.status} ${body}`);
      return JSON.stringify(body);
    } finally {
      await l.stop();
    }
  }],
  ['tcp start_tls! with unread bytes is SocketErr (bytes before the upgrade are never read as TLS), the socket stays plain', async (t) => {
    const r = await t.get(`/tcp/start_tls_unread?port=${port}`);
    ok(r.status === 200 && r.body.startsWith('start_tls=Err(Infra(SocketErr(') && r.body.includes('unread bytes before start_tls') && r.body.endsWith('then_read=Ok("late")'), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  ['tcp start_tls! with a read in flight (a read that lost a race) is SocketErr, the socket stays plain', async (t) => {
    const r = await t.get(`/tcp/start_tls_pending?port=${port}`);
    ok(r.status === 200 && r.body.startsWith('first=1 start_tls=Err(Infra(SocketErr(') && r.body.includes('read is in flight') && r.body.endsWith('then_echo=Ok("ping")'), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  ['hyperdrive connect!, connect (Io twin): a Tcp socket to the origin of the binding', async (t) =>
    answer(await t.get('/hyperdrive/connect?name=PGECHO'), 'write=Ok({}) read=Ok(Got("hd")) twin: write=Ok({}) read=Ok(Got("hd"))')],
];
