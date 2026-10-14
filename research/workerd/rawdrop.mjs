// node rawdrop.mjs <port> <id-prefix> <rst|fin> [ms]: raw HTTP/1.1 requests, the socket is closed after 300 ms.
import net from 'node:net';
const [port, pre, how, ms = '3000'] = process.argv.slice(2);
for (const mode of ['js', 'shared', 'fresh']) for (const kind of ['timer', 'fetch', 'never']) {
  const s = net.connect(Number(port), '127.0.0.1', () => s.write(`GET /wait?id=${pre}-${mode}-${kind}&kind=${kind}&mode=${mode}&ms=${ms}&tm=2000 HTTP/1.1\r\nHost: x\r\n\r\n`));
  s.on('data', () => {}); s.on('error', () => {});
  setTimeout(() => (how === 'rst' ? s.resetAndDestroy() : s.end()), 300);
}
