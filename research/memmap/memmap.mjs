#!/usr/bin/env node
// Memory map of one wasm instance (PLAN.md step 12-pre).
// Usage: node research/memmap/memmap.mjs <app.wasm> [--map <file.map>] [--kind app|deep] [--detail] [--json] [--light]
// Method: parse the wasm (memory, globals, data segments, name section) and the wasm-ld map (symbol
// addresses: research/memmap/build.sh writes it). Instantiate it with the stub import of
// bench/core.js (`env.js_wait`, copied in `makeWait` below, no import from bench/), run `init`, then a
// mix of requests (waits, traps, cancels, a failed allocation, `dbg` lines, stack overflow).
// After each phase, compare the static part of memory with the copy taken after `init`.
// The heap part is read from the unit tables of hostlib/alloc.zig (U_KIND, U_SLOT, ...).
// Exit 0: every region is in a row of the PLAN 12 table "What a host bug can damage", and no constant region was written.
// 1: a region is not in the table, or a constant region was written. 2: usage, or the map does not match the wasm.
// Env: MEMMAP_ONE='<request>' replaces the first request (app kind). MEMMAP_WILD=<address> flips one byte there after
// the first request (a test of the checks). MEMMAP_TRACE=1 prints the bursts to stderr.
// --light: small requests and 16 at once (the boxy build is slow). --detail: one row for each data symbol.
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';

// ---------------------------------------------------------------- arguments
const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i < 0 ? null : args.splice(i, 2)[1];
};
const flag = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
};
let mapArg = opt('--map');
const kindArg = opt('--kind');
const detail = flag('--detail');
// --light: smaller requests and fewer at once, for the boxy build (it is slow: 200 items take 1.4 s).
const light = flag('--light');
const asJson = flag('--json');
const file = args[0];
if (!file) {
  console.error('usage: memmap.mjs <app.wasm> [--map <file.map>] [--kind app|deep] [--detail] [--json] [--light]');
  process.exit(2);
}
const kind = kindArg ?? (/deep/.test(file) ? 'deep' : 'app');
const buf = readFileSync(file);
// No --map: use <file without .wasm>.map when it exists.
if (!mapArg && existsSync(file.replace(/\.wasm$/, '.map'))) mapArg = file.replace(/\.wasm$/, '.map');

// ---------------------------------------------------------------- the PLAN 12 table
// The ten rows of "What a host bug can damage", in the order of PLAN.md.
const ROWS = {
  1: 'Task pages and large blocks',
  2: 'Saved stack copy',
  3: 'Wait record',
  4: 'Shared stack',
  5: 'Free units, page reserve',
  6: 'Allocator tables, task records, reserve table',
  7: 'Constant data',
  8: 'Host globals',
  9: 'Pages of the roc runtime (foreign units)',
  10: 'JS blocks',
};
// What 12d does with a row.
const ACTION = {
  1: 'sum at wait (12a, 12b)',
  2: 'sum at wait (12a, 12b)',
  3: 'fields in the sum (12a)',
  4: 'none',
  5: 'none',
  6: 'structural check (12d)',
  7: 'sum at init, check (12d)',
  8: 'range check (12d)',
  9: 'sum if constant, else range (12d)',
  10: 'owner and length (12b)',
};

// ---------------------------------------------------------------- wasm parser
function parseWasm(b) {
  let p = 8;
  const uleb = () => {
    let r = 0n, s = 0n, c;
    do { c = b[p++]; r |= BigInt(c & 0x7f) << s; s += 7n; } while (c & 0x80);
    return Number(r);
  };
  const sleb = () => {
    let r = 0n, s = 0n, c;
    do { c = b[p++]; r |= BigInt(c & 0x7f) << s; s += 7n; } while (c & 0x80);
    if (c & 0x40) r -= 1n << s;
    return Number(r);
  };
  const str = () => { const n = uleb(); const s = b.toString('utf8', p, p + n); p += n; return s; };
  const constExpr = () => {
    let v = null;
    for (let op = b[p++]; op !== 0x0b; op = b[p++]) {
      if (op === 0x41 || op === 0x42) v = sleb();
      else if (op === 0x23) { uleb(); v = null; } else throw new Error(`const expr opcode 0x${op.toString(16)}`);
    }
    return v;
  };
  if (b.readUInt32LE(0) !== 0x6d736100) throw new Error('not a wasm module');
  const w = { memory: null, globals: [], exports: [], imports: [], segments: [], funcNames: 0, dataNames: [] };
  while (p < b.length) {
    const id = b[p++];
    const size = uleb();
    const end = p + size;
    if (id === 2) {
      for (let n = uleb(); n > 0; n--) {
        const mod = str(), name = str(), k = b[p++];
        if (k === 0) uleb();
        else if (k === 1) { p++; const f = uleb(); uleb(); if (f & 1) uleb(); }
        else if (k === 2) { const f = uleb(); uleb(); if (f & 1) uleb(); } else if (k === 3) p += 2;
        w.imports.push({ mod, name, kind: k });
      }
    } else if (id === 5) {
      uleb();
      const f = uleb(), min = uleb(), max = f & 1 ? uleb() : null;
      w.memory = { min, max };
    } else if (id === 6) {
      for (let n = uleb(); n > 0; n--) { p++; const mut = b[p++]; w.globals.push({ mut, init: constExpr() }); }
    } else if (id === 7) {
      for (let n = uleb(); n > 0; n--) { const name = str(), k = b[p++], idx = uleb(); w.exports.push({ name, kind: k, idx }); }
    } else if (id === 11) {
      for (let n = uleb(); n > 0; n--) {
        const f = uleb();
        if (f === 2) uleb();
        const off = f === 1 ? null : constExpr();
        const len = uleb();
        w.segments.push({ off, len });
        p += len;
      }
    } else if (id === 0) {
      if (str() === 'name') {
        while (p < end) {
          const sub = b[p++], sz = uleb(), e = p + sz;
          if (sub === 1) w.funcNames = uleb();
          else if (sub === 9) for (let n = uleb(); n > 0; n--) { const i = uleb(); w.dataNames.push([i, str()]); }
          p = e;
        }
      }
    }
    p = end;
  }
  return w;
}

// ---------------------------------------------------------------- wasm-ld map
// Columns: Addr(8) Off(8) Size(8), then the text. Out sections have no indent, input sections 8, symbols 16.
function parseMap(text) {
  const syms = [], secs = {};
  let inData = false, out = null, origin = null, isec = null;
  for (const line of text.split('\n')) {
    if (line.length < 28) continue;
    const addr = line.slice(0, 8).trim(), size = parseInt(line.slice(18, 26), 16);
    const t = line.slice(27);
    const indent = t.length - t.trimStart().length;
    const name = t.trim();
    if (indent === 0) {
      // After DATA: each line without indent that has an address is an output section (.rodata, .data, .bss, and
      // sections that the roc runtime adds, such as roc_boxy_sidecar_blob).
      if (name === 'DATA') inData = true;
      else if (inData && addr !== '-') { out = name; secs[name] = { start: parseInt(addr, 16), size }; }
    } else if (!inData) continue;
    else if (indent === 8) {
      origin = name.includes('host.wasm') ? 'host' : 'roc';
      isec = /\((\.[a-z]+(?:\.rel\.ro)?)\./.exec(name)?.[1] ?? out;
    } else if (indent === 16 && size > 0) {
      syms.push({ name: name.replace(/^\.L/, ''), addr: parseInt(addr, 16), size, out, origin, isec });
    }
  }
  return { syms, secs };
}

// ---------------------------------------------------------------- symbol rules (data and bss)
// [pattern, group, PLAN row]. Row 'bench': only a bench export writes it (PLAN 7a). Rodata is row 7.
const RULES = [
  // [pattern, group, PLAN row, constant by design (written only by init)]
  [/^alloc\.U_/, 'unit tables (U_*)', 6],
  [/^alloc\.(FREE_BITS|RL_FLBITS|RL_SLBITS|RL_HEAD|LOW_HINT)$/, 'free-run index', 6],
  [/^alloc\.(POOL_LO|POOL_HI|GROWN_END|CHUNKS_USED)$/, 'pool bounds', 6],
  [/^alloc\.(CACHE|CACHED)$/, 'page reserve table', 6],
  [/^alloc\.(TASKS|SLOT_OWNER|LAST_OWNER|LAST_SLOT)$/, 'task records', 6],
  [/^alloc\.FREE_MARK$/, 'free mark (set once)', 8, true],
  [/^alloc\.(OWNER|FAIL_AT|LIVE_BYTES|DOUBLE_FREES|DEALLOC_MISS|ROC_BYTES)$/, 'allocator globals, counters', 8],
  [/^roc\.LOG$/, 'log', 8],
  [/^canary\./, 'canary globals (init only)', 8, true],
  [/^mem\.TRAP_CLEAN$/, 'trap flag', 8],
  [/^host\.(COPY|TASK_TOP|TASK_WAITING|TASK_SAVED|TASK_SAVED_MAX|TASK_SAVED_PEAK|TASK_WAITS|WAITS_FREE_HINT)$/, 'host globals', 8],
  [/^host\.WAITS$/, 'WAITS (pointers to Wait records)', 8],
  [/^host\.(FILL|FILLED|FILL_TAG)$/, 'bench only: heap_fill', 'bench'],
  [/^host\.FAULT_NEXT$/, 'bench only: fault_next_wait', 'bench'],
  [/^roc\.RocHostOf.*\.(host|env)$/, 'roc host table', 7, true],
  [/^roc_boxy_sidecar/, 'roc runtime sidecar (constant data of the boxy runtime)', 7, true],
  [/^alloc\.vtable$/, 'allocator vtable', 7, true],
];
function classify(s) {
  if (s.isec === '.rodata' || s.isec === '.data.rel.ro') return { group: s.origin === 'host' ? 'rodata (host)' : 'rodata (roc)', row: 7, constant: true };
  for (const [re, group, row, constant] of RULES) if (re.test(s.name)) return { group, row, constant: !!constant };
  // A static of the Roc side or of an unknown host file: no row.
  return { group: `${s.origin === 'roc' ? 'Roc side' : 'host'} statics (${s.isec})`, row: null, constant: false };
}

// ---------------------------------------------------------------- inputs
const wasm = parseWasm(buf);
let map = null;
let mapNote = 'no map: coarse regions only';
if (mapArg) {
  map = parseMap(readFileSync(mapArg, 'utf8'));
  // The map must describe this file: each active data segment lies in .rodata or .data of the map.
  const ro = map.secs['.rodata'], bs = map.secs['.bss'];
  // Every active data segment must lie in an output section of the map before .bss.
  const lo = ro?.start, hi = bs ? bs.start : null;
  const bad = lo == null || hi == null || wasm.segments.some((s) => s.off != null && (s.off < lo || s.off + s.len > hi));
  if (bad || !bs) {
    mapNote = 'the map does not match this wasm: ignored';
    map = null;
  } else mapNote = `${mapArg} (${map.syms.length} data symbols)`;
}

const MEM_PAGE = 65536;
const sp0 = wasm.globals[0]?.init ?? 0; // __stack_pointer at start: the top of the shared stack
const initialBytes = wasm.memory.min * MEM_PAGE;

// ---------------------------------------------------------------- the instance (stub of bench/core.js)
const dec = new TextDecoder();
const enc = new TextEncoder();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const st = { tasks: new Map(), nextId: 1, waiting: 0, onWait: null, sleepMs: 5, outcome: {} };
const cell = { x: null };

function newTask() {
  const t = { id: st.nextId++, cancelled: false, hostFreed: false, ended5: false, waiting: false };
  t.cancelP = new Promise((r) => (t.wake = r));
  st.tasks.set(t.id, t);
  return t;
}
// Cancel a waiting task: the host frees its record and pages, the wait answers with status 5 (PLAN 3c).
function cancelTask(t) {
  if (!t.waiting || t.cancelled) return false;
  t.cancelled = true;
  if (!t.hostFreed) {
    t.hostFreed = true;
    try { cell.x.task_cancel(t.id); } catch {}
  }
  t.wake();
  return true;
}
const reply = (k, a, b) => {
  if (k === 1) { try { return 'f:' + new URL(b).searchParams.get('id'); } catch { return 'f:?'; } }
  return 'd:' + (a.split(' ')[1] ?? 'x');
};
// The wait import. It reads its arguments before the first await (they can be on the shared stack).
const wait = async (k, num, ap, al, bp, bl, cp, cl, out, id) => {
  const x = cell.x;
  const u8 = new Uint8Array(x.memory.buffer);
  const a = dec.decode(u8.subarray(ap, ap + al));
  const b = dec.decode(u8.subarray(bp, bp + bl));
  const t = st.tasks.get(id);
  if (t?.cancelled) { t.ended5 = true; return 5; }
  st.waiting++;
  t.waiting = true;
  if (process.env.MEMMAP_TRACE) console.error('wait', id, st.waiting);
  st.onWait?.(st.waiting, id);
  try {
    await Promise.race([sleep(st.sleepMs), t.cancelP]);
  } finally {
    t.waiting = false;
    st.waiting--;
  }
  if (t.cancelled) { t.ended5 = true; return 5; }
  const body = enc.encode(reply(k, a, b));
  const p = x.js_alloc(body.length);
  if (!p) return 4;
  new Uint8Array(x.memory.buffer).set(body, p);
  const dv = new DataView(x.memory.buffer);
  dv.setUint32(out, p, true);
  dv.setUint32(out + 4, body.length, true);
  return 200;
};

const importObj = { env: {} };
for (const im of WebAssembly.Module.imports(new WebAssembly.Module(buf))) {
  importObj[im.module] ??= {};
  importObj[im.module][im.name] = im.name === 'js_wait' ? new WebAssembly.Suspending(wait) : () => 0;
}
const module = new WebAssembly.Module(buf);
const inst = new WebAssembly.Instance(module, importObj);
const x = (cell.x = inst.exports);
const handle = WebAssembly.promising(x.handle);

// ---------------------------------------------------------------- memory access
const mem8 = () => new Uint8Array(x.memory.buffer);
const dv = () => new DataView(x.memory.buffer);
const rd32 = (a) => dv().getUint32(a, true);
const sym = (name) => map?.syms.find((s) => s.name === name);
const A = (name) => sym(name)?.addr;

// ---------------------------------------------------------------- snapshots
const phases = [];
let initCopy = null; // static memory after `init`
let instCopy = null; // static memory right after instantiate
let staticEnd = initialBytes;
let firstChange = null; // for each static byte: the index (1 based) of the first phase that changed it
const heapSnaps = {}; // label -> unit counts

function snapStatic(label) {
  const idx = phases.length + 1;
  phases.push(label);
  const cur = new Uint32Array(x.memory.buffer, 0, staticEnd >> 2);
  const ini = new Uint32Array(initCopy.buffer, 0, staticEnd >> 2);
  const fc = firstChange;
  for (let i = 0; i < cur.length; i++) {
    if (cur[i] === ini[i]) continue;
    const cb = new Uint8Array(x.memory.buffer, i << 2, 4), ib = new Uint8Array(initCopy.buffer, i << 2, 4);
    for (let k = 0; k < 4; k++) if (cb[k] !== ib[k] && fc[(i << 2) + k] === 0) fc[(i << 2) + k] = idx;
  }
  return idx;
}

// Units of the heap by kind, owner and use (hostlib/alloc.zig: U_KIND, U_SLOT, U_UNITS, FREE_BITS, CACHE).
function heapCount() {
  const uk = sym('alloc.U_KIND');
  if (!uk) return null;
  const maxUnits = uk.size;
  const lo = rd32(A('alloc.POOL_LO')), hi = rd32(A('alloc.POOL_HI'));
  const u8 = mem8(), d = dv();
  const kindOf = (i) => u8[A('alloc.U_KIND') + i];
  const slotOf = (i) => u8[A('alloc.U_SLOT') + i];
  const unitsOf = (i) => d.getUint16(A('alloc.U_UNITS') + 2 * i, true);
  const isFree = (i) => (d.getUint32(A('alloc.FREE_BITS') + 4 * (i >> 5), true) >>> (i & 31)) & 1;
  const jsSlot = sym('alloc.SLOT_OWNER').size / 4 - 1;
  const cached = rd32(A('alloc.CACHED'));
  const reserve = new Set();
  for (let k = 0; k < cached; k++) reserve.add(d.getUint16(A('alloc.CACHE') + 2 * k, true));
  const c = { poolLo: lo, poolHi: hi, maxUnits, free: [], reserve: [], smallHost: [], smallJs: [], smallTask: [], largeHost: [], largeJs: [], largeTask: [], foreign: [], other: [], largeBlocks: 0, smallPages: 0, taskSlots: new Set() };
  for (let i = lo; i < hi; i++) {
    const k = kindOf(i), s = slotOf(i);
    const part = s === 0 ? 'Host' : s === jsSlot ? 'Js' : 'Task';
    if (k === 0) (isFree(i) ? c.free : reserve.has(i) ? c.reserve : c.other).push(i);
    else if (k === 1) { c['small' + part].push(i); c.smallPages++; if (part === 'Task') c.taskSlots.add(s); }
    else if (k === 2) {
      const n = unitsOf(i);
      for (let j = 0; j < n; j++) c['large' + part].push(i + j);
      i += n - 1;
      c.largeBlocks++;
      if (part === 'Task') c.taskSlots.add(s);
    } else if (k === 4) c.foreign.push(i);
    else c.other.push(i);
  }
  return c;
}

// The Wait records (host.WAITS): [low, top, buf ptr, buf len, out0, out1, owner, at] in host/host.zig.
function waitRecords() {
  const a = A('host.WAITS');
  if (!a) return null;
  const n = sym('host.WAITS').size / 4, d = dv();
  const recs = [];
  for (let i = 0; i < n; i++) {
    const p = d.getUint32(a + 4 * i, true);
    if (!p) continue;
    const f = [...Array(8).keys()].map((k) => d.getUint32(p + 4 * k, true));
    recs.push({ at: p, low: f[0], top: f[1], buf: f[2], len: f[3], owner: f[6], index: f[7], slot: i, ok: f[1] - f[0] === f[3] && f[7] === i });
  }
  return recs;
}

// Foreign units (roc runtime pages): a copy at the first snapshot that has them, then compared at each one.
const foreignCopy = new Map();
const foreignChanged = new Map();
let foreignFirst = null;
function snapHeap(label) {
  const c = heapCount();
  if (!c) return;
  const u8 = mem8();
  for (const i of c.foreign) {
    const cur = u8.subarray(i << 12, (i + 1) << 12);
    if (!foreignCopy.has(i)) { foreignCopy.set(i, cur.slice()); foreignFirst ??= label; } else if (!foreignChanged.has(i) && Buffer.compare(cur, foreignCopy.get(i)) !== 0) foreignChanged.set(i, label);
  }
  c.waits = waitRecords();
  heapSnaps[label] = c;
}

// ---------------------------------------------------------------- requests
const logLines = [];
const drainLog = () => {
  const n = x.log_len();
  if (n === 0) return;
  const w = new Uint32Array(x.memory.buffer, x.log_ptr(), n);
  for (let i = 0; i + 2 < n; i += 3) logLines.push(dec.decode(new Uint8Array(x.memory.buffer, w[i], w[i + 1])));
  x.log_clear();
};
const tally = {};
const count = (k) => (tally[k] = (tally[k] ?? 0) + 1);

async function runReq(req, onResponse) {
  const t = newTask();
  const bytes = enc.encode(req);
  const p = x.js_alloc(bytes.length);
  if (!p) { count('js_alloc 0'); return; }
  new Uint8Array(x.memory.buffer).set(bytes, p);
  try {
    const blk = await handle(p, bytes.length, t.id);
    onResponse?.();
    const len = rd32(blk);
    const body = dec.decode(new Uint8Array(x.memory.buffer, blk + 4, len));
    x.res_free(blk);
    drainLog();
    count(body.length ? 'ok' : 'empty body');
  } catch (e) {
    if (t.ended5) { count('cancelled (status 5)'); return; }
    const freed = x.task_abort(t.id);
    if (freed === -1 || freed === 0xffffffff) count('trap, NOT clean');
    else { count('trap, clean'); drainLog(); }
  }
}

// Start `reqs` at once. When all wait, `atAllWaiting(tasks)` runs once (a snapshot, cancels, a failed alloc).
async function burst(label, reqs, atAllWaiting) {
  if (process.env.MEMMAP_TRACE) console.error('burst', label, reqs.length);
  const tasksBefore = st.nextId;
  let fired = false;
  st.onWait = (n) => {
    if (fired || n !== reqs.length) return;
    fired = true;
    const ids = [];
    for (let id = tasksBefore; id < st.nextId; id++) ids.push(id);
    atAllWaiting?.(ids);
  };
  let respSnap = false;
  await Promise.all(reqs.map((r) => runReq(r, () => {
    if (!respSnap && label === 'one request') { respSnap = true; snapHeap('response block'); }
  })));
  st.onWait = null;
  snapStatic(label);
  snapHeap(label);
}

// ---------------------------------------------------------------- run
instCopy = new Uint8Array(new Uint8Array(x.memory.buffer, 0, staticEnd).slice());
// As bench/core.js: the free mark first, then init.
x.set_free_mark?.(crypto.getRandomValues(new Uint32Array(1))[0] | 1);
x.init(1);
staticEnd = initialBytes;
initCopy = new Uint8Array(new Uint8Array(x.memory.buffer, 0, staticEnd).slice());
firstChange = new Uint8Array(staticEnd);
const mapCheck = A('canary.CANARY_BASE') ? (rd32(A('canary.STACK_LIMIT')) - rd32(A('canary.CANARY_BASE')) === 4096 ? 'ok (STACK_LIMIT - CANARY_BASE = 4096 at the mapped addresses)' : 'FAILED: the map does not match this wasm') : 'no map';
if (mapCheck.startsWith('FAILED')) { console.error(mapCheck); process.exit(2); }
const statusInit = { memBytes: x.memory.buffer.byteLength, canaryOk: x.stack_canary_ok?.(), stackFirst: x.stack_first?.() };
snapHeap('init');

// Test hook: MEMMAP_WILD=<address> flips one byte there after the first request (a wild write). The map must show it.
const wild = () => {
  if (process.env.MEMMAP_WILD) new Uint8Array(x.memory.buffer)[Number(process.env.MEMMAP_WILD)] ^= 1;
};
const midWaiting = (label) => () => { snapStatic(label); snapHeap(label); };
const N = light ? 16 : 64;
const ITEMS_S = light ? 20 : 200, ITEMS_L = light ? 50 : 2000, DEEP = light ? 100 : 400;
if (kind === 'app') {
  await burst('one request', [process.env.MEMMAP_ONE ?? `1 0 50 ${ITEMS_S}`]);
  wild();
  // Requests one after another: does the roc runtime take more pages at each one?
  for (let i = 1; i <= 4; i++) await burst(`seq ${i}`, [`${10 + i} 0 50 ${ITEMS_S}`]);
  const many = Array.from({ length: N }, (_, i) => `${1000 + i} 0 ${i % 16 === 0 ? DEEP : 50} ${i % 8 === 0 ? ITEMS_L : ITEMS_S}`);
  await burst('many', many, midWaiting('many, all waiting'));
  const faults = Array.from({ length: 24 }, (_, i) => `${2000 + i} ${i % 6 === 1 ? 1 : 0} 50 ${ITEMS_S}${i === 5 || i === 11 ? ' dbg' : ''}`);
  await burst('faults', faults, (ids) => {
    midWaiting('faults, all waiting')();
    for (const id of [ids[3], ids[9], ids[15]]) cancelTask(st.tasks.get(id));
    x.fail_next_alloc?.();
  });
} else {
  await burst('one request', ['5']);
  wild();
  const depths = [10, 100, 400, 1000, 2000, 3000];
  const many = Array.from({ length: N }, (_, i) => `${depths[i % depths.length]}${i % 2 ? ' alloc' : ''}`);
  await burst('many', many, midWaiting('many, all waiting'));
  await burst('overflow, no alloc', ['100000']);
  await burst('overflow, alloc', ['100000 alloc']);
  const faults = Array.from({ length: 16 }, (_, i) => `${200 + i}`);
  await burst('faults', faults, (ids) => {
    midWaiting('faults, all waiting')();
    for (const id of [ids[2], ids[7], ids[11]]) cancelTask(st.tasks.get(id));
    x.fail_next_alloc?.();
  });
}
x.log_clear?.();
await sleep(20);
snapStatic('idle');
snapHeap('idle');
if (x.heap_fill) {
  x.heap_fill(1000, 64, 5);
  snapStatic('bench: heap_fill');
  x.heap_fill(0, 0, 0);
  snapStatic('bench: heap_fill freed');
  snapHeap('after bench');
}
const final = { live: x.live_bytes?.(), waiting: x.task_waiting?.(), canaryOk: x.stack_canary_ok?.(), memBytes: x.memory.buffer.byteLength, missed: x.dealloc_miss?.() };
// Unclean traps (an out-of-bounds write, `unreachable`, a wrapped stack pointer): task_abort gives -1, the pages stay.
// In production the instance is replaced then (PLAN 12c). Run last, so the checks above are not touched.
if (x.fault_next_wait) {
  for (const k of [1, 2, 3]) {
    x.fault_next_wait(k);
    await burst(`unclean trap ${k}`, [kind === 'deep' ? '5' : `${30 + k} 0 50 ${ITEMS_S}`]);
  }
}

// ---------------------------------------------------------------- regions
const regions = [];
const add = (r) => regions.push(r);
const fmt = (n) => n.toLocaleString('en-US');
const hex = (n) => '0x' + n.toString(16).padStart(6, '0');

// Changes of the byte range [s, e) against the copy after init.
function changed(s, e) {
  let n = 0, lo = -1, hi = -1, first = 0;
  s = Math.min(s, staticEnd);
  e = Math.min(e, staticEnd);
  for (let i = s; i < e; i++) {
    if (!firstChange[i]) continue;
    n++;
    if (lo < 0) lo = i;
    hi = i;
    if (!first || firstChange[i] < first) first = firstChange[i];
  }
  return { n, lo, hi, first };
}
function byInit(s, e) {
  let n = 0;
  for (let i = s; i < Math.min(e, staticEnd); i++) if (instCopy[i] !== initCopy[i]) n++;
  return n;
}
function writtenText(c, size) {
  if (c.n === 0) return 'no';
  return `yes: ${fmt(c.n)} of ${fmt(size)} B, ${hex(c.lo)} to ${hex(c.hi + 1)}`;
}

const addStatic = (name, start, end, row, extra = {}) => {
  if (end <= start) return;
  const c = changed(start, end);
  add({ name, start, end, size: end - start, row, written: writtenText(c, end - start), writtenN: c.n, firstPhase: c.first ? phases[c.first - 1] : '', byInit: byInit(start, end), ...extra });
};

const canaryBase = A('canary.CANARY_BASE') ? rd32(A('canary.CANARY_BASE')) : null;
let dataStart = sp0;
if (canaryBase != null && sp0) {
  addStatic('stack, guard below the canary', 0, canaryBase, 4);
  addStatic('stack canary (4 KB, written by init)', canaryBase, canaryBase + 4096, 7, { note: 'host constant', constant: true });
  addStatic('shared stack', canaryBase + 4096, sp0, 4);
} else if (sp0) addStatic('stack', 0, sp0, 4);

let bssEnd = sp0;
if (map) {
  // Atoms: the data symbols in address order, padding between them goes to the symbol before.
  const syms = [...map.syms].sort((a, b) => a.addr - b.addr || b.size - a.size);
  const atoms = [];
  let cursor = null;
  for (const s of syms) {
    if (cursor != null && s.addr < cursor) continue; // an alias inside the previous symbol
    const cl = classify(s);
    atoms.push({ ...s, ...cl, end: s.addr + s.size });
    cursor = s.addr + s.size;
  }
  // Group atoms: adjacent atoms of one group make one region. The extent runs to the next group.
  const groups = [];
  for (const a of atoms) {
    const g = groups[groups.length - 1];
    if (g && g.group === a.group && g.row === a.row) { g.end = a.end; g.syms.push(a); } else groups.push({ group: a.group, row: a.row, constant: a.constant, start: a.addr, end: a.end, syms: [a] });
  }
  for (let i = 0; i < groups.length; i++) if (i + 1 < groups.length) groups[i].end = groups[i + 1].start;
  const lastSym = groups[groups.length - 1];
  const bss = map.secs['.bss'];
  lastSym.end = bss.start + bss.size;
  bssEnd = lastSym.end;
  // Merge neighbors with the same row and the same written state (fewer, longer regions).
  const merged = [];
  for (const g of groups) {
    g.names = [g.group];
    g.w = changed(g.start, g.end).n > 0;
    const m = merged[merged.length - 1];
    if (m && m.row === g.row && m.w === g.w && m.constant === g.constant) { m.end = g.end; m.syms.push(...g.syms); if (!m.names.includes(g.group)) m.names.push(g.group); } else merged.push(g);
  }
  if (groups[0].start > sp0) addStatic('gap between stack and data', sp0, groups[0].start, 5, { padding: true });
  for (const g of merged) addStatic(g.names.join(', '), g.start, g.end, g.row, { syms: g.syms, bench: g.row === 'bench', constant: g.constant });
  if (initialBytes > bssEnd) addStatic('unused tail of the initial memory', bssEnd, initialBytes, 5, { padding: true });
} else {
  const segs = wasm.segments.filter((s) => s.off != null);
  const lo = sp0, hi = Math.max(...segs.map((s) => s.off + s.len));
  addStatic('data segments (no map: constant and not constant mixed)', lo, hi, 7, { note: 'the map splits this' });
  addStatic('bss, free tail of the initial memory (no map)', hi, initialBytes, null, { note: 'needs the map' });
}

// Heap regions, from the last snapshot with the most tasks (the peak) and from idle.
const peak = heapSnaps['many, all waiting'] ?? heapSnaps['idle'];
const idle = heapSnaps['idle'];
const heapRows = [];
if (peak) {
  const mid = peak;
  const ext = (a) => (a.length ? [Math.min(...a) << 12, (Math.max(...a) + 1) << 12] : [0, 0]);
  const recs = mid.waits ?? [];
  const copyBytes = recs.reduce((s, r) => s + r.len, 0);
  const waitOk = recs.length > 0 && recs.every((r) => r.ok);
  const row = (name, units, rowId, note = '') => {
    const [s, e] = ext(units);
    heapRows.push({ name, start: s, end: e, units: units.length, size: units.length << 12, row: rowId, note });
  };
  row('free units', mid.free, 5);
  row('page reserve (empty small pages)', mid.reserve, 5);
  row('task small pages', mid.smallTask, 1, `${mid.taskSlots.size} task slots`);
  row('task large blocks', mid.largeTask, 1, `${fmt(copyBytes)} B of it are ${recs.length} saved stack copies (row 2), found by the Wait records${waitOk ? '' : ' (layout check failed)'}`);
  row('host pages (slot 0)', [...mid.smallHost, ...mid.largeHost], 3, `Wait records (${recs.length} x 32 B), log lines; the response block is here for a short time`);
  row('JS pages (slot JS)', [...mid.smallJs, ...mid.largeJs], 10, 'request blocks and response blocks of js_alloc');
  row('foreign units (roc runtime)', mid.foreign, 9);
  row('unit of kind none, not free, not reserve', mid.other, null);
  heapRows.copyBytes = copyBytes;
  heapRows.waitOk = waitOk;
  heapRows.recs = recs.length;
}
// The pool and the area around it.
const poolLo = heapSnaps.init ? heapSnaps.init.poolLo : null;
const lastHeap = heapSnaps.idle ?? heapSnaps['faults'];
const poolHiBytes = lastHeap ? lastHeap.poolHi << 12 : null;
const poolLoBytes = lastHeap ? lastHeap.poolLo << 12 : null;
const extra = [];
if (poolLoBytes != null) {
  if (poolLoBytes > staticEnd) extra.push({ name: 'gap: memory grown by other code before the first pool use', start: staticEnd, end: poolLoBytes, row: null });
  if (final.memBytes > poolHiBytes) extra.push({ name: 'memory above the pool (grown, not yet in the tables)', start: poolHiBytes, end: final.memBytes, row: null });
}

// ---------------------------------------------------------------- output
const unmapped = [];
const rowName = (r) => (r === 'bench' ? 'none (bench only)' : r == null ? 'NONE' : `${r}. ${ROWS[r]}`);
const out = [];
const p = (s = '') => out.push(s);
const sha = createHash('sha256').update(buf).digest('hex').slice(0, 16);

p(`# Memory map: ${file}`);
p();
p(`| Item | Value |`);
p(`|---|---|`);
p(`| File | ${file}, ${fmt(buf.length)} B, sha256 ${sha} |`);
p(`| Request mix | ${kind === 'deep' ? 'app_deep' : 'app'}: ${phases.join(', ')} |`);
p(`| Map check | ${mapCheck} |`);
p(`| Symbols | ${mapNote}; name section: ${wasm.funcNames} function names, ${wasm.dataNames.length} data names |`);
p(`| Memory at start | ${wasm.memory.min} pages (${fmt(initialBytes)} B), maximum ${wasm.memory.max ?? 'none'}; at the end ${fmt(final.memBytes)} B |`);
p(`| Stack | top ${hex(sp0)} (the start of __stack_pointer), stack first: ${statusInit.stackFirst}, canary ok after init: ${statusInit.canaryOk} |`);
p(`| Requests | ${Object.entries(tally).map(([k, v]) => `${k}: ${v}`).join(', ')} |`);
p(`| After the unclean traps | live bytes ${x.live_bytes?.()}, canary ok ${x.stack_canary_ok?.()} (the pages of an unclean task stay: the instance is replaced in production) |`);
p(`| At the end of the clean phases | live bytes ${final.live}, tasks waiting ${final.waiting}, dealloc_miss ${final.missed}, canary ok ${final.canaryOk}, log lines ${logLines.length} |`);
p();
p('## Static regions (below the pool)');
p();
p('"After init": bytes that changed against the copy taken after `init`, at any snapshot. "By init": bytes that `init` and `set_free_mark` changed against the instance as made. Rows are the rows of the PLAN 12 table "What a host bug can damage".');
p();
p('| Region | Start | End | Size B | Written after init | By init B | PLAN 12 row |');
p('|---|---|---|---|---|---|---|');
for (const r of regions) {
  const rid = r.row;
  if (rid == null && !r.padding) unmapped.push(r.name);
  if (r.padding && r.writtenN > 0) unmapped.push(r.name + ' (padding, written)');
  const rn = r.padding ? (r.writtenN ? 'NONE (padding is written)' : '5 (nobody writes it)') : rowName(rid) + (r.note ? ` (${r.note})` : '');
  p(`| ${r.name} | ${hex(r.start)} | ${hex(r.end)} | ${fmt(r.size)} | ${r.written}${r.firstPhase && r.writtenN ? `; first in "${r.firstPhase}"` : ''} | ${r.byInit} | ${rn} |`);
}
p();
p('## Heap (units of 4 KB, read from the unit tables)');
p();
if (!peak) p('No map: the unit tables are not found, the heap is not classified.');
if (peak) {
  p(`Pool at the end: ${hex(poolLoBytes)} to ${hex(poolHiBytes)} (${fmt(poolHiBytes - poolLoBytes)} B). Counts are from the snapshot with ${heapRows.recs} tasks waiting; "At idle" is the last snapshot with no task.`);
  p();
  p('| Region | Lowest unit start | Highest unit end | Units | Size B | At idle, units | PLAN 12 row |');
  p('|---|---|---|---|---|---|---|');
  const idleOf = { 'free units': idle?.free, 'page reserve (empty small pages)': idle?.reserve, 'task small pages': idle?.smallTask, 'task large blocks': idle?.largeTask, 'host pages (slot 0)': idle && [...idle.smallHost, ...idle.largeHost], 'JS pages (slot JS)': idle && [...idle.smallJs, ...idle.largeJs], 'foreign units (roc runtime)': idle?.foreign, 'unit of kind none, not free, not reserve': idle?.other };
  for (const r of heapRows) {
    if (r.row == null && r.units > 0) unmapped.push(r.name);
    p(`| ${r.name}${r.note ? ` (${r.note})` : ''} | ${r.units ? hex(r.start) : '-'} | ${r.units ? hex(r.end) : '-'} | ${fmt(r.units)} | ${fmt(r.size)} | ${idleOf[r.name]?.length ?? '-'} | ${r.units === 0 && r.row == null ? 'none (empty)' : rowName(r.row)} |`);
  }
  p();
  const fi = heapSnaps.init;
  p(`After init the pool has ${fi.poolHi - fi.poolLo} units: every unit of the heap is written after init (nothing of the heap is constant from init). Wait record layout (low, top, copy ptr, copy len, out, owner, at): ${heapRows.waitOk ? 'checked for all records (top - low = copy length, index = slot)' : 'NOT confirmed'}.`);
  p();
  const resp = heapSnaps['response block'];
  if (resp) p(`Host pages (slot 0) when the response block of the first request exists (between \`handle\` and \`res_free\`): ${resp.smallHost.length + resp.largeHost.length} units, with ${resp.smallJs.length + resp.largeJs.length} JS units. After that request: ${(heapSnaps['one request']?.smallHost.length ?? 0) + (heapSnaps['one request']?.largeHost.length ?? 0)} host units.`);
  p();
  p('| Foreign units | Value |');
  p('|---|---|');
  p(`| After init | ${fi.foreign.length} |`);
  p(`| At the peak, at idle | ${peak.foreign.length}, ${idle.foreign.length} |`);
  p(`| First seen in the snapshot | ${foreignFirst ?? 'never'} |`);
  p(`| Units by snapshot | ${Object.entries(heapSnaps).filter(([k]) => k !== 'response block').map(([k, v]) => `${k}: ${v.foreign.length}`).join('; ')} |`);
  p(`| Changed after the first snapshot that has them | ${foreignChanged.size} of ${foreignCopy.size} units${foreignChanged.size ? `, first changed in "${[...foreignChanged.values()][0]}"` : ''} |`);
  if (foreignCopy.size) {
    // Runs of units: constant (c) and changed (m), in address order.
    const runs = [];
    for (const i of [...foreignCopy.keys()].sort((a, b) => a - b)) {
      const k = foreignChanged.has(i) ? 'changed' : 'constant';
      const l = runs[runs.length - 1];
      if (l && l.k === k && l.end === i) l.end = i + 1; else runs.push({ k, start: i, end: i + 1 });
    }
    const show = runs.slice(0, 12).map((r) => `${r.k} ${hex(r.start << 12)} to ${hex(r.end << 12)}`).join('; ');
    p(`| Runs of foreign units (${runs.length}) | ${show}${runs.length > 12 ? '; ...' : ''} |`);
  }
  p();
}
if (extra.length) {
  p('| Other region | Start | End | Size B | PLAN 12 row |');
  p('|---|---|---|---|---|');
  for (const r of extra) { unmapped.push(r.name); p(`| ${r.name} | ${hex(r.start)} | ${hex(r.end)} | ${fmt(r.end - r.start)} | NONE |`); }
  p();
}

// Constant after init: regions that the code writes only in init, and that no request changed.
p('## Constant after init');
p();
p('Ranges that only `init` (or `set_free_mark`, called before it) writes, and that no request changed. Neighbors are joined. 12d sums these after init.');
p();
p('| Range | Size B | What |');
p('|---|---|---|');
const constRegions = regions.filter((r) => r.constant && r.writtenN === 0);
const ranges = [];
for (const r of constRegions) {
  const l = ranges[ranges.length - 1];
  if (l && l.end === r.start) { l.end = r.end; l.what.push(r.name); } else ranges.push({ start: r.start, end: r.end, what: [r.name] });
}
let constBytes = 0;
for (const r of ranges) {
  constBytes += r.end - r.start;
  p(`| ${hex(r.start)} to ${hex(r.end)} | ${fmt(r.end - r.start)} | ${[...new Set(r.what)].join(', ')} |`);
}
p(`| Total, static | ${fmt(constBytes)} | |`);
const constForeign = foreignCopy.size - foreignChanged.size;
p(`| Constant foreign units (unchanged after first seen) | ${fmt(constForeign << 12)} | ${constForeign} units |`);
p();
const brokeConst = regions.filter((r) => r.constant && r.writtenN > 0);
const idleRow8 = regions.filter((r) => r.row === 8 && !r.constant && r.writtenN === 0);
const mutable = regions.filter((r) => r.writtenN > 0 && r.row !== 4 && r.row !== 'bench');
p('## Written after init (not the stack)');
p();
p('| Region | Written | PLAN 12 row | 12d |');
p('|---|---|---|---|');
for (const r of mutable) p(`| ${r.name} | ${r.written} | ${rowName(r.row)} | ${r.row == null ? 'NONE' : ACTION[r.row]} |`);
p();
if (detail) {
  p('## Detail: each symbol of the data and bss');
  p();
  p('| Symbol | Start | Size B | Section | Origin | Written after init | PLAN 12 row |');
  p('|---|---|---|---|---|---|---|');
  for (const r of regions) for (const s of r.syms ?? []) {
    const c = changed(s.addr, s.addr + s.size);
    p(`| ${s.name} | ${hex(s.addr)} | ${fmt(s.size)} | ${s.isec} | ${s.origin} | ${writtenText(c, s.size)} | ${rowName(classify(s).row)} |`);
  }
  p();
}
// Writes outside any region of the static map (should be none).
const stray = regions.reduce((s, r) => s + r.size, 0);
p('## Check');
p();
p('| Check | Result |');
p('|---|---|');
p(`| Static regions cover the initial memory | ${fmt(stray)} of ${fmt(initialBytes)} B |`);
p(`| Constant by design but written | ${brokeConst.length ? brokeConst.map((r) => r.name).join('; ') : 'none'} |`);
p(`| Row 8 regions not written in this mix (writable by design, so not constant) | ${idleRow8.length ? idleRow8.map((r) => r.name).join('; ') : 'none'} |`);
p(`| Regions with no PLAN 12 row | ${unmapped.length ? unmapped.join('; ') : 'none'} |`);
p(`| Canary and live bytes at the end of the clean phases | canary ok ${final.canaryOk}, live bytes ${final.live} |`);
const bench = regions.filter((r) => r.bench);
if (bench.length) p(`| Bench-only regions (not in a production build, PLAN 7a) | ${bench.map((r) => `${r.name}, ${fmt(r.size)} B`).join('; ')} |`);
p();
p(unmapped.length === 0 ? 'RESULT: every region is in a row of the PLAN 12 table.' : `RESULT: ${unmapped.length} region(s) are not in the table.`);
if (brokeConst.length) p(`RESULT: ${brokeConst.length} constant region(s) were written: ${brokeConst.map((r) => r.name).join('; ')}.`);

if (asJson) console.log(JSON.stringify({ file, foreignBySnap: Object.fromEntries(Object.entries(heapSnaps).map(([k, v]) => [k, v.foreign.length])), regions: regions.map(({ syms, ...r }) => r), heap: heapRows, unmapped, final, tally }, null, 1));
else console.log(out.join('\n'));
process.exit(unmapped.length || brokeConst.length ? 1 : 0);
