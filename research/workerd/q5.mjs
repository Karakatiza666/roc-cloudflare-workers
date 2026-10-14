// node q5.mjs <port> <pid> <scenario> [secs=60]: drop a 30 MB memory, then time until FinalizationRegistry reports it.
// idle: one /log poll each 1 s. poll: one poll each 100 ms. load: 64 requests at once that make JS garbage.
// pressure: each 1 s a new 30 MB memory is made and kept (what a grow after a drop does).
import { readFileSync } from 'node:fs';
const [port, pid, sc, secs = '60'] = process.argv.slice(2);
const B = `http://127.0.0.1:${port}`;
const rss = () => Math.round(Number(/VmRSS:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]) / 1024);
const id = `q5-${sc}-${Date.now()}`;
const r0 = rss();
const t0 = Date.now();
await (await fetch(`${B}/mem?id=${id}&mb=30`)).text();
let stop = false, done = null, reqs = 0;
if (sc === 'load') for (let k = 0; k < 64; k++) (async () => { while (!stop) { await (await fetch(`${B}/load?n=2000&ms=5`)).text(); reqs++; } })();
const every = sc === 'poll' || sc === 'load' ? 100 : 1000;
let made = 0;
while (Date.now() - t0 < Number(secs) * 1000) {
  await new Promise((r) => setTimeout(r, every));
  if (sc === 'pressure') { await (await fetch(`${B}/mem?id=${id}-p${made++}&mb=30&hold=1`)).text(); }
  const l = (await (await fetch(B + '/log')).json()).log;
  const f = l.find((e) => e.id === id + ':mem' && e.what === 'finalized');
  if (f) { done = { ms: Date.now() - t0 }; break; }
}
stop = true;
console.log({ scenario: sc, finalizedAfterMs: done?.ms ?? `never in ${secs} s`, rssMB: [r0, rss()], loadRequests: reqs, pressureMBmade: made * 30 });
