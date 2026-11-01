// What a WebSocket client of Node does with its TCP connection when it fails the connection (RFC 6455 4.1: the 101 has
// no protocol of the ones that the client asked for), and what the server end in workerd then gets, in plain JS with no
// platform (PLAN.md "Status of the conformance run on Node 26.13"). A Worker answers each upgrade with a `WebSocketPair`
// with the protocol `v3`, and logs the events of its end. The client asks for `chat`. Two clients: `WebSocket` of Node
// (undici) and the `ws` package of Miniflare. After 1 s: the events of the server end, and the TCP connections of this
// process to workerd that are open (`ss`). The log is read with `dispatchFetch` (its own pool, not the pool of undici
// that the `WebSocket` of Node uses).
//   MINIFLARE=<dir of miniflare> node research/ws-fail-probe/probe.mjs   (output: research/ws-fail-probe/out.txt)
import { execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = process.env.MINIFLARE ?? join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const req = createRequire(import.meta.url);
const { Miniflare, convertV4MiniflareOptions } = req(mfDir);
const W = req(join(dirname(mfDir), 'ws'));

const script = `
const log = [];
export default { async fetch(request) {
  const u = new URL(request.url);
  if (u.pathname === '/log') return new Response(log.splice(0).join(' | ') || '(no event)');
  const [c, s] = Object.values(new WebSocketPair());
  s.accept();
  const ev = (x) => log.push(x);
  s.addEventListener('message', (e) => ev('message ' + e.data));
  s.addEventListener('close', (e) => ev('close ' + e.code + ' clean=' + e.wasClean));
  s.addEventListener('error', (e) => ev('error "' + e.message + '" retryable=' + e.error?.retryable));
  return new Response(null, { status: 101, webSocket: c, headers: { 'Sec-WebSocket-Protocol': 'v3' } });
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', port: 0 }));
const base = String(await mf.ready);
const port = new URL(base).port;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// The TCP connections of this process to the port of workerd.
const open = () => execSync(`ss -tnp state established dst 127.0.0.1:${port}`).toString().split('\n').filter((l) => l.includes(`pid=${process.pid},`)).length;

const node = (url) => new Promise((r) => {
  const ws = new WebSocket(url, ['chat']);
  ws.addEventListener('close', (e) => r(`close ${e.code}`));
});
const wsPkg = (url) => new Promise((r) => {
  const ws = new W.WebSocket(url, ['chat']);
  ws.on('error', (e) => r(`error "${e.message}"`));
  ws.on('open', () => r('open'));
});

console.log(`node ${process.version}, ${execSync(`${join(dirname(mfDir), '@cloudflare/workerd-linux-64/bin/workerd')} --version`).toString().trim()}`);
for (const [name, f] of [['WebSocket of Node', node], ['ws package', wsPkg]]) {
  for (let i = 1; i <= 2; i++) {
    const client = await f(base.replace('http', 'ws') + 'ws');
    await sleep(1000);
    const server = await (await mf.dispatchFetch('http://localhost/log')).text();
    console.log(`${name}, round ${i}: client: ${client}; server end after 1 s: ${server}; TCP connections open: ${open()}`);
  }
}
await mf.dispose();
process.exit(0);
