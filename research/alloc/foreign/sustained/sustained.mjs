// Sustained concurrent load on ONE workerd isolate; samples x-roc-stats of every response (research/alloc/foreign/sustained).
//   node sustained.mjs --edge <dir with app.wasm + .roc-cfw> --scenario mixed --n 20000 --c 10 --out <file.jsonl> [--mix a,b]
// --mix: several scenarios, lines interleaved round robin (e.g. mixed,releases). Output: one JSON line per response, in
// completion order: {i, status, bytes, ms, mem, livePeak, liveEnd, grows, served}.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync, createWriteStream } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const prof = resolve(here, '../../../regprof');
const opt = {};
for (let i = 2; i < process.argv.length; i += 2) opt[process.argv[i].slice(2)] = process.argv[i + 1];
const n = Number(opt.n ?? 20000), c = Number(opt.c ?? 10);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJsonl = (f) => readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const names = (opt.mix ?? opt.scenario ?? 'mixed').split(',');
const sets = names.map((s) => readJsonl(join(prof, 'scenarios', `${s}.jsonl`)));
const lines = [];
for (let k = 0; sets.some((s) => k < s.length); k++) for (const s of sets) if (k < s.length) lines.push(s[k]);

let counter = 1n << 40n;
const fill = (s) => (typeof s === 'string' && s.includes('{{uniq}}') ? s.replaceAll('{{uniq}}', () => (counter++).toString(16).padStart(32, '0')) : s);
async function send(base, line) {
  const headers = { 'user-agent': 'tln-bench/0', accept: 'application/json', ...Object.fromEntries(Object.entries(line.headers ?? {}).map(([k, v]) => [k.toLowerCase(), fill(v)])) };
  let body;
  if (line.json !== undefined) { body = fill(JSON.stringify(line.json)); headers['content-type'] ??= 'application/json'; }
  else if (line.body !== undefined) body = fill(line.body);
  const r = await fetch(base + line.path, { method: line.method, headers, body, redirect: 'manual' });
  const buf = Buffer.from(await r.arrayBuffer());
  const st = r.headers.get('x-roc-stats');
  const s = st ? JSON.parse(st) : {};
  return { status: r.status, bytes: buf.length, mem: s.mem, livePeak: s.livePeak, liveEnd: s.liveEnd, grows: s.grows, served: s.served };
}

const state = join(prof, 'state');
rmSync(join(state, 'worker.url'), { force: true });
const env = { ...process.env, W2_DIR: resolve(opt.edge), TALON_NOW: '2026-11-07T12:00:00Z', MINIFLARE_WORKERD_V8_FLAGS: '', CFW_TEST_OPTIONS: JSON.stringify({ stats: true, resumeCheck: 'off', heapCheckEvery: 0, heapCheckWhenIdle: false }) };
delete env.CFW_TEST_TRACE;
const srv = spawn(join(prof, 'serve.sh'), [], { env, stdio: ['ignore', 'ignore', 'inherit'] });
try {
  for (let i = 0; !existsSync(join(state, 'worker.url')); i++) { if (i > 600 || srv.exitCode !== null) throw new Error('no server'); await sleep(200); }
  const base = readFileSync(join(state, 'worker.url'), 'utf8').trim();
  const out = createWriteStream(opt.out);
  let next = 0, done = 0, bad = 0;
  const t0 = Date.now();
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= n) return;
      const t = Date.now();
      let r;
      try { r = await send(base, lines[i % lines.length]); } catch (e) { r = { status: 0, err: String(e) }; }
      if (r.status === 0 || r.status >= 500) bad++;
      out.write(JSON.stringify({ i, ms: Date.now() - t, ...r }) + '\n');
      if (++done % 2000 === 0) console.error(`${done}/${n} ${((Date.now() - t0) / 1000).toFixed(0)} s mem ${(r.mem / 2 ** 20).toFixed(2)} MB bad ${bad}`);
    }
  };
  await Promise.all(Array.from({ length: c }, worker));
  await new Promise((r) => out.end(r));
  console.error(`done ${n} requests, ${bad} bad, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  await fetch(`${base}/__regserve/stop`, { method: 'POST' }).catch(() => {});
} finally {
  await Promise.race([new Promise((r) => srv.on('close', r)), sleep(15000)]);
  if (srv.exitCode === null) srv.kill('SIGKILL');
}
