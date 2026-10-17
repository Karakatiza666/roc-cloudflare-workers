// A small STARTTLS server (PLAN.md 11c, EP6, EP11): the SMTP steps of the edge probe in research/starttls, and the local
// STARTTLS check of conformance/checks/tcp.mjs.
//   220 banner; EHLO -> 250 STARTTLS; STARTTLS -> 220 and a TLS upgrade; EHLO in TLS -> 250; QUIT -> 221.
// Each event goes to `log` with its time, so a run shows if the bytes of a client arrived (a write that hangs) or not.
// CLI (a run from another place: the edge): node research/starttls/server.mjs <port> <cert.pem> <key.pem>
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { TLSSocket } from 'node:tls';

export function startServer({ cert, key, port = 0, host = '127.0.0.1' }) {
  const log = [];
  const t0 = Date.now();
  const note = (conn, what) => log.push({ ms: Date.now() - t0, conn, what });
  let conns = 0;
  const server = createServer((raw) => {
    const id = ++conns;
    note(id, 'connect');
    let sock = raw;
    let tls = false;
    const attach = (s) => {
      let buf = '';
      s.on('data', (d) => {
        buf += d.toString();
        for (;;) {
          const i = buf.indexOf('\r\n');
          if (i < 0) break;
          const line = buf.slice(0, i);
          buf = buf.slice(i + 2);
          note(id, `${tls ? 'tls ' : ''}recv ${JSON.stringify(line)}`);
          const cmd = line.split(' ')[0].toUpperCase();
          if (cmd === 'EHLO') s.write(tls ? '250 localhost secure\r\n' : '250-localhost\r\n250 STARTTLS\r\n');
          else if (cmd === 'STARTTLS' && !tls) {
            s.write('220 2.0.0 Ready to start TLS\r\n', () => {
              raw.removeAllListeners('data');
              sock = new TLSSocket(raw, { isServer: true, cert, key });
              tls = true;
              note(id, 'tls upgrade');
              attach(sock);
            });
            return;
          } else if (cmd === 'QUIT') s.end('221 bye\r\n');
          else s.write('500 what\r\n');
        }
      });
      s.on('error', (e) => note(id, `error ${e.message}`));
      s.on('close', () => note(id, 'close'));
    };
    attach(raw);
    raw.write('220 localhost ESMTP starttls-probe\r\n');
  });
  return new Promise((resolve) => server.listen(port, host, () => resolve({ server, log, port: server.address().port })));
}

// A test certificate for `localhost` and 127.0.0.1 (needs `openssl`): `cert.pem` and `key.pem` in `dir`.
export function makeCert(dir) {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', `${dir}/key.pem`, '-out', `${dir}/cert.pem`, '-days', '30', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], { stdio: 'ignore' });
  return { cert: readFileSync(`${dir}/cert.pem`), key: readFileSync(`${dir}/key.pem`), certFile: `${dir}/cert.pem` };
}
