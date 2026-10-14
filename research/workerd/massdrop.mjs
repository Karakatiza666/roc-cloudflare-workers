// node massdrop.mjs <port> <pid> <mode> <n>: n requests that wait forever (kind=never), each dropped with RST.
// Prints workerd RSS before, after the drops, and after GC.
import net from 'node:net';
import { readFileSync } from 'node:fs';
const [port, pid, mode, n] = process.argv.slice(2);
const rss = () => Math.round(Number(/VmRSS:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]) / 1024);
const B = `http://127.0.0.1:${port}`;
const gc = async () => { for (let i = 0; i < 3; i++) { await fetch(B + '/gc'); await fetch(B + '/load'); } };
await gc();
const r0 = rss();
const drop = (id) => new Promise((res) => {
  const s = net.connect(Number(port), '127.0.0.1', () => s.write(`GET /wait?id=${id}&kind=${process.env.KIND ?? "never"}&mode=${mode} HTTP/1.1\r\nHost: x\r\n\r\n`));
  s.on('error', () => {});
  setTimeout(() => { s.resetAndDestroy(); res(); }, 50);
});
for (let i = 0; i < Number(n); i += 50) await Promise.all(Array.from({ length: 50 }, (_, k) => drop(`m-${mode}-${i + k}`)));
const r1 = rss();
await gc(); await new Promise((r) => setTimeout(r, 1000)); await gc();
const r2 = rss();
const l = (await (await fetch(B + '/log')).json()).log.filter((e) => e.id.startsWith(`m-${mode}-`));
const fin = (s) => l.filter((e) => e.what === 'finalized' && e.id.endsWith(s)).length;
console.log({ mode, n: Number(n), rssMB: [r0, r1, r2], perTaskKB: +(((r2 - r0) * 1024) / n).toFixed(1), tokensFinalized: fin(':token'), instancesFinalized: fin(':instance') });
