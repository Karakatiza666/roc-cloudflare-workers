// Tables and CSV from out/*.jsonl.  node report.mjs  ->  results.md fragment on stdout, series.csv written.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const D = join(dirname(fileURLToPath(import.meta.url)), 'out');
const MB = (x) => (x / 2 ** 20).toFixed(2);
const rows = [], csv = {};
for (const f of readdirSync(D).filter((x) => x.endsWith('.jsonl')).sort()) {
  const [sc, v, c] = f.replace('.jsonl', '').split('-');
  // mem is the instance memory at the response; order by `served` (the server order), not by completion at the client.
  const r = readFileSync(join(D, f), 'utf8').trim().split('\n').map(JSON.parse).filter((x) => x.mem).sort((a, b) => a.served - b.served);
  const n = r.length, third = Math.floor(n / 3);
  const memAt = (k) => r[Math.min(n - 1, k)].mem;
  const maxMem = Math.max(...r.map((x) => x.mem));
  const peakRow = r.find((x) => x.mem === maxMem);
  const maxLive = Math.max(...r.map((x) => x.livePeak));
  const last = r.slice(2 * third);
  const growLast = memAt(n - 1) - memAt(2 * third);
  const growMid = memAt(2 * third) - memAt(third);
  const bad = r.filter((x) => x.status >= 500).length;
  rows.push({ sc, v, c, n, bad, final: MB(memAt(n - 1)), max: MB(maxMem), livePeakAtMax: (peakRow.livePeak / 1024).toFixed(0), maxLive: (maxLive / 1024).toFixed(0), ratio: (maxMem / maxLive).toFixed(2), growMid: (growMid / 1024).toFixed(0), growLast: (growLast / 1024).toFixed(0), grows: r.reduce((a, x) => a + x.grows, 0), maxLiveEnd: (Math.max(...last.map((x) => x.liveEnd)) / 1024).toFixed(0), still: growLast > 0 ? 'yes' : 'no', t90: r.findIndex((x) => x.mem >= 0.9 * maxMem) });
  const pts = []; for (let k = 0; k < 100; k++) pts.push(memAt(Math.floor(((k + 1) / 100) * n) - 1));
  csv[`${sc}-${v}-${c}`] = pts;
}
console.log('| scenario | variant | c | requests | 5xx | final mem MB | max mem MB | max livePeak KB | livePeak at max mem KB | max mem / max livePeak | growth 2nd third KB | growth last third KB | still growing | requests to 90 % of max |');
console.log('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
for (const x of rows) console.log(`| ${x.sc} | ${x.v} | ${x.c} | ${x.n} | ${x.bad} | ${x.final} | ${x.max} | ${x.maxLive} | ${x.livePeakAtMax} | ${x.ratio} | ${x.growMid} | ${x.growLast} | ${x.still} | ${x.t90} |`);
const keys = Object.keys(csv);
writeFileSync(join(D, '..', 'series.csv'), ['point(1%=n/100 requests)', ...keys].join(',') + '\n' + csv[keys[0]].map((_, k) => [k + 1, ...keys.map((q) => (csv[q][k] / 2 ** 20).toFixed(3))].join(',')).join('\n') + '\n');
