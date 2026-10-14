// node bigok.mjs <port> <pid> <n>: n completed requests, each with its own 1 MB instance (control for massdrop big).
import { readFileSync } from 'node:fs';
const [port, pid, n] = process.argv.slice(2);
const rss = () => Math.round(Number(/VmRSS:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]) / 1024);
const B = `http://127.0.0.1:${port}`;
const gc = async () => { for (let i = 0; i < 3; i++) { await fetch(B + '/gc'); await fetch(B + '/load'); } };
await gc(); const r0 = rss();
for (let i = 0; i < Number(n); i += 50) await Promise.all(Array.from({ length: 50 }, (_, k) => fetch(`${B}/wait?id=ok-${i + k}&kind=timer&ms=10&mode=big`).then((r) => r.text())));
const r1 = rss(); await gc(); await new Promise((r) => setTimeout(r, 1000)); await gc(); const r2 = rss();
const l = (await (await fetch(B + '/log')).json()).log.filter((e) => e.id.startsWith('ok-') && e.what === 'finalized' && e.id.endsWith(':instance'));
console.log({ n: Number(n), rssMB: [r0, r1, r2], instancesFinalized: l.length });
