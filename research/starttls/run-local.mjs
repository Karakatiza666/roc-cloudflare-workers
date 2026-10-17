// PLAN.md 11c, EP6: runs the probe worker (worker.js) in the local workerd against a local STARTTLS server (server.mjs).
//   WORKERD=<workerd binary> node research/starttls/run-local.mjs
// Needs: `openssl` (a test certificate in research/starttls/out/, git-ignored), a free port 8431 and the port of the server.
// Output: one block for each variant (the steps with their result and time), then what the server saw.
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startServer } from './server.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const WORKERD = process.env.WORKERD;
if (!WORKERD) throw new Error('set WORKERD');
const out = join(here, 'out');
mkdirSync(out, { recursive: true });
if (!existsSync(join(out, 'cert.pem'))) {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(out, 'key.pem'), '-out', join(out, 'cert.pem'), '-days', '30', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], { stdio: 'ignore' });
}
const { server, log, port } = await startServer({ cert: readFileSync(join(out, 'cert.pem')), key: readFileSync(join(out, 'key.pem')) });
const BASE = 'http://127.0.0.1:8431';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const p = spawn(WORKERD, ['serve', '--experimental', join(here, 'config.capnp')], { stdio: ['ignore', 'ignore', 'inherit'], cwd: here });
// workerd must not outlive this script (a signal skips `finally`).
process.on('exit', () => p.kill('SIGKILL'));
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => process.exit(130));
try {
  let up = false;
  for (let i = 0; i < 100 && !up; i++) {
    await sleep(100);
    try { up = (await fetch(`${BASE}/none`)).status === 404; } catch {}
  }
  if (!up) throw new Error('workerd did not start');
  const variants = [
    ['raw: starttls, allowHalfOpen false (as the shim)', `/raw?mode=starttls&half=false`],
    ['raw: starttls, allowHalfOpen not given', `/raw?mode=starttls&half=none`],
    ['raw: starttls, allowHalfOpen true', `/raw?mode=starttls&half=true`],
    ['raw: starttls, a new reader and writer for each step', `/raw?mode=starttls&half=false&relock=1`],
    ['raw: starttls, EHLO written before the banner is read', `/raw?mode=starttls&half=false&early=1`],
    ['raw: starttls, the reader and the writer stay locked at startTls() (as the shim keeps them)', `/raw?mode=starttls&half=false&locked=1`],
    ['raw: off (control, no upgrade)', `/raw?mode=off&half=false&upgrade=0`],
    ['shim: tcpConnect starttls, tcpRead, tcpWrite, tcpStartTls', `/shim?mode=starttls`],
    ['shim: off (control, no upgrade)', `/shim?mode=off&upgrade=0`],
  ];
  let bad = 0;
  for (const [label, path] of variants) {
    log.length = 0;
    const res = await (await fetch(`${BASE}${path}&host=127.0.0.1&port=${port}`)).json();
    console.log(`\n== ${label}   (${path})`);
    if (res.error) { console.log(`   ${res.error}`); bad++; continue; }
    for (const s of res.steps) console.log(`   ${String(s.ms).padStart(5)} ms  ${s.result.padEnd(7)} ${s.step}${s.value ? `: ${s.value}` : ''}${s.error ? `: ${s.error}` : ''}`);
    const last = res.steps[res.steps.length - 1];
    if (last.result !== 'ok') bad++;
    console.log(`   server saw: ${log.map((l) => l.what).join(' | ')}`);
  }
  console.log(`\n${bad ? `${bad} variant(s) did not finish` : 'all variants finished'}`);
} finally {
  p.kill('SIGTERM');
  server.close();
}
