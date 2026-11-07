// CPU profile of the registry Worker under a scenario of talon/research/bench (see README.md here).
// The Worker runs in workerd (regserve.mjs, inspector on INSPECT_PORT). This script uses the V8 profiler of
// several workerd isolates at once, and the CPU time of the workerd and node processes (/proc).
//   node regprof.mjs --scenario small [--dir scenarios] [--warm 2] [--repeat 5] [--interval 50]
//        [--base http://127.0.0.1:8787] [--inspect 9230] [--app w2/app.wasm] [--host <platform host.wasm>]
//        [--first] [--out <prefix>] [--json]
//   --first   profile from the first request of a fresh server (no warm-up): the startup cost.
// Prints, per request: wall ms, workerd and node process CPU ms, and the self time of each part (table).
import { readFileSync, writeFileSync, readdirSync, readlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { wasmInfo } from './wasminfo.mjs';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, x, i, all) => (x.startsWith('--') ? [...a, [x.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : 'true']] : a), []));
const here = new URL('.', import.meta.url).pathname;
const base = (args.base ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
const port = Number(args.inspect ?? 9230);
const dir = args.dir ?? `${here}scenarios`;
const first = args.first === 'true';
const warm = first ? 0 : Number(args.warm ?? 2);
const repeat = Number(args.repeat ?? 5);
const interval = Number(args.interval ?? 50);
const appWasm = args.app ?? `${here}w2/app.wasm`;
const hostWasm = args.host;
const TARGETS = (args.targets ?? 'core:user:,d1:db,d1:db:entry,core:entry').split(',');

// ---- function names of the wasm: the host part of app.wasm, aligned with the host.wasm of the platform.
// The roc linker puts the host functions first (in host order, a few dropped), then the Roc code.
function hostNames() {
  const app = wasmInfo(readFileSync(appWasm));
  const names = new Map();
  for (const [n, i] of app.exports) names.set(i, n);
  if (!hostWasm) return { names, firstRoc: null };
  const h = wasmInfo(readFileSync(hostWasm));
  const hByName = new Map([...h.names].map(([i, n]) => [n, i]));
  // Anchors: exported names in both. Between anchors, align by body size (host functions may be dropped).
  const anchors = app.exports.map(([n, i]) => [hByName.get(n), i]).filter(([hi]) => hi !== undefined).sort((a, b) => a[0] - b[0]);
  const hs = (k) => h.bodies[k - h.importFuncs]?.size ?? 0;
  const as = (k) => app.bodies[k - app.importFuncs]?.size ?? 0;
  const lastHost = h.importFuncs + h.bodies.length - 1;
  const lastAnchor = anchors[anchors.length - 1];
  const firstRoc = lastAnchor[1] + (lastHost - lastAnchor[0]) + 1 - 0; // upper bound: no drop after the last anchor
  const segs = [[h.importFuncs - 1, app.importFuncs - 1], ...anchors, [lastHost + 1, firstRoc]];
  for (let s = 0; s + 1 < segs.length; s++) {
    const [h0, a0] = segs[s], [h1, a1] = segs[s + 1];
    const nh = h1 - h0 - 1, na = a1 - a0 - 1;
    if (na < 0 || nh < na) continue;
    // DP: map na app functions to nh host functions in order, cost |size difference|.
    const cost = (i, j) => Math.abs(hs(h0 + 1 + i) - as(a0 + 1 + j)) / Math.max(1, hs(h0 + 1 + i));
    const D = Array.from({ length: nh + 1 }, () => new Float64Array(na + 1).fill(Infinity));
    D[0][0] = 0;
    for (let i = 1; i <= nh; i++) for (let j = 0; j <= Math.min(i, na); j++) D[i][j] = Math.min(D[i - 1][j] + 0.5, j ? D[i - 1][j - 1] + cost(i - 1, j - 1) : Infinity);
    for (let i = nh, j = na; i > 0;) {
      if (j && D[i][j] === D[i - 1][j - 1] + cost(i - 1, j - 1)) { const n = h.names.get(h0 + i); if (n && !names.has(a0 + j)) names.set(a0 + j, n); i--; j--; } else i--;
    }
  }
  return { names, firstRoc };
}

// ---- parts
function partOf(fn, url, names, firstRoc) {
  if (fn === '(idle)') return 'idle';
  if (fn === '(garbage collector)') return 'V8 GC';
  if (fn === '(program)' || fn === '(root)') return 'V8 and workerd (no JS frame)';
  if (url.startsWith('wasm://') || /^\$?func\d+|^wasm-function\[/.test(fn)) {
    const k = Number((/(\d+)/.exec(fn) ?? [])[1]);
    const n = names.get(k) ?? (/^[a-z_.$A-Z]/.test(fn) && !/^\$?func|^wasm-function/.test(fn) ? fn : null);
    if (firstRoc !== null && k >= firstRoc) return 'wasm: Roc (app and builtins)';
    if (!n) return firstRoc === null ? 'wasm (no names)' : 'wasm: host (no name)';
    if (/alloc|Alloc|dealloc|Dealloc|realloc|Realloc|smallFree|smallTake|release|taskOf|taskEnd|runGive|runTake|runFind|takeLow|freeOwner|adopt|poolGrow|liveAdd|smallGive|availPush|availRemove/.test(n)) return `wasm: host allocator`;
    if (/fletcher|sumTask|sumAdopted|sum_|check_heap|checkTables/.test(n)) return 'wasm: host sums and checks';
    if (/cbor|Cbor|CBOR/.test(n)) return 'wasm: host CBOR codec';
    if (/json|Json|JSON/.test(n)) return 'wasm: host JSON';
    if (/memcpy|memset|memmove|copyBytes/.test(n)) return 'wasm: host memcpy';
    return `wasm: host other`;
  }
  if (/\/\.roc-cfw\//.test(url)) {
    const f = url.split('/').pop();
    return `JS shim (${f})`;
  }
  if (/__cfw_test_entry|hooks\.js|worker\.js/.test(url)) return 'JS entry and test hooks';
  if (url === '') return `JS builtins (${fn})`.startsWith('JS builtins (JSON') ? 'JS builtins: JSON' : 'JS builtins (other)';
  if (/^(node:|cloudflare:|cloudflare-internal:|workerd:|internal:)/.test(url) || !/^file:|^\//.test(url)) return 'workerd JS internals';
  return 'JS other';
}

// ---- CDP
async function cdp(target) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/${target}`);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  let id = 0;
  const wait = new Map();
  ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && wait.has(d.id)) { const [ok, bad] = wait.get(d.id); wait.delete(d.id); d.error ? bad(new Error(JSON.stringify(d.error))) : ok(d.result); } };
  return { send: (method, params = {}) => new Promise((ok, bad) => { const i = ++id; wait.set(i, [ok, bad]); ws.send(JSON.stringify({ id: i, method, params })); }), close: () => ws.close() };
}

// ---- process CPU (/proc/<pid>/stat utime + stime, in ticks of 10 ms)
const pidsOf = () => {
  const out = execFileSync('pgrep', ['-f', '--', `--inspector-addr=127.0.0.1:${port}`], { encoding: 'utf8' }).trim().split('\n').map(Number);
  const wd = out.find((p) => { try { return readlinkSync(`/proc/${p}/exe`).endsWith('/workerd'); } catch { return false; } });
  const ppid = Number(readFileSync(`/proc/${wd}/stat`, 'utf8').split(') ')[1].split(' ')[1]);
  return { workerd: wd, node: ppid };
};
const cpuMs = (pid) => { const f = readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' '); return (Number(f[11]) + Number(f[12])) * 10; };
const threadsCpuMs = (pid) => readdirSync(`/proc/${pid}/task`).reduce((a, t) => { const f = readFileSync(`/proc/${pid}/task/${t}/stat`, 'utf8').split(') ')[1].split(' '); return a + (Number(f[11]) + Number(f[12])) * 10; }, 0);

// ---- requests
const lines = (args.scenario ?? 'small').split(',').flatMap((n) => readFileSync(`${dir}/${n}.jsonl`, 'utf8').trim().split('\n').map((l) => JSON.parse(l)));
let uniqN = 0n;
const fill = (s) => (typeof s === 'string' ? s.replaceAll('{{uniq}}', () => (BigInt(Date.now()) * 4294967296n + uniqN++).toString(16).padStart(32, '0')) : s);
async function send(l) {
  const headers = { 'user-agent': 'tln-bench/0', accept: 'application/json', ...(args.identity === 'true' ? { 'accept-encoding': 'identity' } : {}), ...Object.fromEntries(Object.entries(l.headers ?? {}).map(([k, v]) => [k.toLowerCase(), fill(v)])) };
  let body;
  if (l.json !== undefined) { body = fill(JSON.stringify(l.json)); headers['content-type'] ??= 'application/json'; } else if (l.body !== undefined) body = fill(l.body);
  const t = performance.now();
  const r = await fetch(base + l.path, { method: l.method, headers, body });
  await r.arrayBuffer();
  const ms = performance.now() - t;
  if (r.status !== l.expected_status) bad++;
  return ms;
}
let bad = 0;

const { names, firstRoc } = hostNames();
for (let w = 0; w < warm; w++) for (const l of lines) await send(l);
const { workerd, node } = pidsOf();
if (args.perf === 'true') {
  // perf mode: `perf record` on both processes (all threads, user and kernel), the JIT code names from the
  // jitdump of V8 (workerd runs with MINIFLARE_WORKERD_V8_FLAGS=--perf-prof, cwd = the dir of the dump).
  const { spawn, spawnSync } = await import('node:child_process');
  const data = args.out ? `${args.out}.perf.data` : `${here}perf/perf.data`;
  const rec = spawn('perf', ['record', '-k', '1', '-e', 'cpu-clock', '-F', '10000', '--call-graph', 'fp', '-p', `${workerd}`, '-o', data], { stdio: ['ignore', 'ignore', 'pipe'] });
  await new Promise((ok) => setTimeout(ok, 500));
  const c0 = { w: threadsCpuMs(workerd), n: threadsCpuMs(node) };
  const t0 = performance.now();
  const walls = [];
  const sent = first ? lines.slice(0, 1) : lines;
  for (let r = 0; r < (first ? 1 : repeat); r++) for (const l of sent) walls.push(await send(l));
  const wallAll = performance.now() - t0;
  const c1 = { w: threadsCpuMs(workerd), n: threadsCpuMs(node) };
  rec.kill('SIGINT');
  await new Promise((ok) => rec.on('exit', ok));
  const inj = spawnSync('perf', ['inject', '--jit', '-i', data, '-o', `${data}.jit`], { cwd: `${here}perf`, encoding: 'utf8' });
  if (inj.status !== 0) throw new Error(inj.stderr);
  const reqs = walls.length;
  const { parts: stackParts } = await import('./perfstacks.mjs');
  const pr = stackParts(`${data}.jit`, reqs, names, firstRoc, 0.1);
  const total = pr.total * 0.1;
  const rowsP = pr.rows;
  const med = [...walls].sort((a, b) => a - b)[walls.length >> 1];
  const res = { scenario: args.scenario, first, requests: reqs, statusMismatch: bad, wallMsMedian: +med.toFixed(2), wallMsMean: +(wallAll / reqs).toFixed(2), workerdCpuMs: +((c1.w - c0.w) / reqs).toFixed(2), nodeCpuMs: +((c1.n - c0.n) / reqs).toFixed(2), perfWorkerdMs: +(total / reqs).toFixed(3) };
  const rows = rowsP;
  if (args.json === 'true') console.log(JSON.stringify({ ...res, rows })); else { console.log(res); console.table(rows); }
  process.exit(0);
}

/// The part of one perf symbol. Process: node (Miniflare host, the HTTP proxy of regserve.mjs) or workerd.
function perfPart(comm, dso, kind, sym, names, firstRoc) {
  if (comm.startsWith('node') || comm === 'MainThread' || /^(libuv|V8Worker|node)/.test(comm)) {
    if (dso === '[kernel.kallsyms]') return 'node process: kernel';
    return 'node process (proxy, Miniflare host)';
  }
  // workerd threads
  if (dso === '[kernel.kallsyms]' || kind === 'k') return 'workerd: kernel (syscalls, network, futex)';
  const jit = /^jitted-/.test(dso) || /^JS:|^Builtin:|^BytecodeHandler:|^Stub:|^RegExp:/.test(sym);
  if (jit) {
    const w = /wasm-function\[(\d+)\]/.exec(sym);
    if (w) {
      const k = Number(w[1]);
      const tier = /liftoff/.test(sym) ? ' (Liftoff)' : '';
      if (firstRoc !== null && k >= firstRoc) return `wasm: Roc app and builtins${tier}`;
      const n = names.get(k) ?? '';
      if (/alloc|Alloc|dealloc|realloc|smallFree|smallTake|release|taskOf|taskEnd|runGive|runTake|runFind|takeLow|freeOwner|adopt|poolGrow|smallGive|avail/.test(n)) return 'wasm: host allocator';
      if (/check_heap|checkTables|constSum|globalCheck/.test(n)) return 'wasm: host global check (check_heap)';
      if (/fletcher|sumTask|sumAdopted/.test(n)) return 'wasm: host sums';
      if (/cbor|Cbor/.test(n)) return 'wasm: host CBOR';
      return `wasm: host other`;
    }
    if (/\.roc-cfw\//.test(sym) || /(cbor|values|program|runner|bridge|host|tasks|wait|events|bindings|budget|helpers|index|options|manifest)\.js/.test(sym)) {
      const f = /([a-z-]+\.js)/.exec(sym)?.[1] ?? '?';
      if (/test-entry\.js/.test(sym)) return 'JS: test entry (startApp)';
      return `JS shim (${f})`;
    }
    if (/entry\.worker\.js|miniflare|d1|\$outbound|cache/.test(sym)) return 'JS: Miniflare workers (entry router, D1, cache)';
    if (/hooks\.js/.test(sym)) return 'JS: test hooks';
    if (/^Builtin:|^BytecodeHandler:|^Stub:/.test(sym)) return 'V8 builtins and interpreter (JS of the shim and Miniflare)';
    return 'JS other (JIT)';
  }
  if (/libsqlite|sqlite/i.test(sym) || /^sqlite3/.test(sym)) return 'workerd: SQLite (D1)';
  if (/^(deflate|longest_match|build_tree|compress_block|send_bits|fill_window|crc32|adler32|inflate|_tr_|pqdownheap|gen_bitlen|scan_tree|send_tree)/.test(sym)) return 'workerd: zlib (gzip of the response, Accept-Encoding)';
  if (/tcmalloc|operator new|operator delete/.test(sym)) return 'workerd: C++ malloc (tcmalloc)';
  if (/Scaveng|MarkCompact|Marking|Sweep|ConcurrentMark|::Heap::|heap::base|CppHeap|Weak/.test(sym)) return 'V8 GC';
  if (/^v8::|^Builtins_|v8::internal|^Heap|Scavenge|Mark|Sweep|GC/.test(sym)) return /GC|Scaveng|Mark|Sweep|Heap::/.test(sym) ? 'V8 GC' : 'V8 runtime (C++)';
  if (/kj::|capnp::|workerd::|jsg::|edgeworker/.test(sym)) return 'workerd runtime (C++: HTTP, RPC, JS glue)';
  if (/libc|ld-linux|^__|^mem|^str|malloc|free/.test(dso + ' ' + sym)) return 'libc (memcpy, malloc)';
  return `workerd other (${dso.split('/').pop()})`;
}

const sessions = [];
for (const t of TARGETS) {
  try { const s = await cdp(t); await s.send('Profiler.enable'); await s.send('Profiler.setSamplingInterval', { interval }); sessions.push([t, s]); } catch (e) { console.error(`regprof: no target ${t}`); }
}
for (const [, s] of sessions) await s.send('Profiler.start');
const c0 = { w: threadsCpuMs(workerd), n: threadsCpuMs(node) };
const t0 = performance.now();
const walls = [];
const n = first ? 1 : repeat;
const sent = first ? lines.slice(0, 1) : lines;
for (let r = 0; r < n; r++) for (const l of sent) walls.push(await send(l));
const wallAll = performance.now() - t0;
const c1 = { w: threadsCpuMs(workerd), n: threadsCpuMs(node) };
const reqs = walls.length;
const parts = new Map();
let profiled = 0;
for (const [t, s] of sessions) {
  const { profile } = await s.send('Profiler.stop');
  if (args.out) writeFileSync(`${args.out}.${t.replace(/[^a-z0-9]+/gi, '_')}.cpuprofile`, JSON.stringify(profile));
  const byId = new Map(profile.nodes.map((x) => [x.id, x]));
  const dt = profile.timeDeltas;
  profile.samples.forEach((id, i) => {
    const x = byId.get(id);
    const ms = (dt[i + 1] ?? dt[i] ?? 0) / 1000;
    const part = partOf(x.callFrame.functionName || '(anonymous)', x.callFrame.url || '', names, firstRoc);
    if (part === 'idle') return;
    const key = t === 'core:user:' ? part : `isolate ${t} (${part.startsWith('V8') ? part : 'JS'})`;
    parts.set(key, (parts.get(key) ?? 0) + ms);
    profiled += ms;
  });
  s.close();
}
const med = [...walls].sort((a, b) => a - b)[walls.length >> 1];
const res = { scenario: args.scenario, first, requests: reqs, statusMismatch: bad, wallMsMedian: +med.toFixed(2), wallMsMean: +(wallAll / reqs).toFixed(2), workerdCpuMs: +((c1.w - c0.w) / reqs).toFixed(2), nodeCpuMs: +((c1.n - c0.n) / reqs).toFixed(2), profiledMs: +(profiled / reqs).toFixed(3) };
const rows = [...parts].sort((a, b) => b[1] - a[1]).map(([part, ms]) => ({ part, msPerRequest: +(ms / reqs).toFixed(3), pctOfProfiled: +((100 * ms) / profiled).toFixed(1) }));
if (args.json === 'true') console.log(JSON.stringify({ ...res, rows }));
else { console.log(res); console.table(rows); }
