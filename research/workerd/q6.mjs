// node q6.mjs <port> <inspector port> <conc> <secs>: JS heap of the worker (CDP Runtime.getHeapUsage) idle and under load.
const [port, iport, conc, secs] = process.argv.slice(2).map(Number);
const ws = new WebSocket(`ws://127.0.0.1:${iport}/main`);
await new Promise((r) => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); wait.get(d.id)?.(d.result ?? d.error); });
const cdp = (method, params = {}) => new Promise((r) => { const id = ++n; wait.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const MB = (b) => +(b / 1048576).toFixed(1);
const heap = async () => { const h = await cdp('Runtime.getHeapUsage'); return { used: MB(h.usedSize), total: MB(h.totalSize), embedder: MB(h.embedderHeapUsedSize ?? 0), backing: MB(h.backingStorageSize ?? 0) }; };
console.log('idle', await heap());
let stop = false, done = 0, id = 200000;
const B = `http://127.0.0.1:${port}`;
const workers = Array.from({ length: conc }, async () => { while (!stop) { const r = await fetch(`${B}/h?id=${id++}&trap=0&depth=50`); await r.text(); done++; } });
const samples = [];
const t0 = Date.now();
while (Date.now() - t0 < secs * 1000) { await new Promise((r) => setTimeout(r, 200)); samples.push(await heap()); }
stop = true; await Promise.all(workers);
const max = (k) => Math.max(...samples.map((s) => s[k]));
const med = (k) => { const a = samples.map((s) => s[k]).sort((x, y) => x - y); return a[a.length >> 1]; };
console.log(`load conc ${conc}, ${done} requests:`, { usedMax: max('used'), usedMedian: med('used'), totalMax: max('total'), embedderMax: max('embedder'), backingMax: max('backing') });
console.log('wasm', await (await fetch(B + '/stats')).json());
console.log('after load', await heap());
ws.close();
