// Parts of the workerd CPU from `perf script` call stacks (perf record --call-graph fp, after perf inject --jit).
// Each sample goes to one worker by the JS frame nearest to the root of its stack (the user Worker, the Miniflare
// entry, the Miniflare cache), or to "no JS on the stack". A sample of the user Worker goes to one part by its leaf.
//   node perfstacks.mjs <perf.jit.data> <requests> [app.wasm host.wasm]
import { spawnSync } from 'node:child_process';

const isWasm = (f) => /^JS:.*-\d+-(turbofan|liftoff)$/.test(f) && !/\.js:\d/.test(f);

export function parts(file, requests, names = new Map(), firstRoc = null, msPerSample = 0.1) {
  const out = spawnSync('perf', ['script', '-i', file, '-F', 'comm,ip,sym'], { encoding: 'utf8', maxBuffer: 1 << 30 }).stdout;
  const acc = new Map();
  const add = (k) => acc.set(k, (acc.get(k) ?? 0) + 1);
  let total = 0;
  for (const block of out.split('\n\n')) {
    const lines = block.split('\n').filter((l) => l.trim());
    if (lines.length < 2) continue;
    const frames = lines.slice(1).map((l) => l.trim().replace(/^[0-9a-f]+\s+/, ''));
    total++;
    const isUser = (f) => /\.roc-cfw\/|hooks\.js/.test(f) || isWasm(f);
    const jsFrames = frames.filter((f) => /^JS:/.test(f));
    const root = [...jsFrames].reverse().find((f) => !/node-internal:/.test(f)) ?? jsFrames[jsFrames.length - 1];
    if (!root) { add(rootless(frames)); continue; }
    if (/entry\.worker\.js|miniflare:shared/.test(root)) { add('Miniflare entry worker (routing, not on the edge)'); continue; }
    if (/cache\.worker\.js/.test(root)) { add('Miniflare cache worker (Cache API emulation)'); continue; }
    if (!isUser(root) && !jsFrames.some(isUser)) { add(`other worker JS (${(/ (\S+?):\d/.exec(root) ?? [])[1] ?? root})`); continue; }
    // The user Worker. The leaf decides the part.
    const leaf = frames[0];
    const firstJs = frames.find((f) => /^JS:/.test(f) && !/node-internal:/.test(f));
    if (firstJs && isWasm(firstJs)) {
      const k = Number(/-(\d+)-(turbofan|liftoff)/.exec(firstJs)[1]);
      const own = /^JS:(.*)-\d+-(turbofan|liftoff)/.exec(firstJs)[1];
      if (!/^JS:/.test(leaf)) {
        const below = frames.slice(0, frames.indexOf(firstJs)).join(' ');
        if (/Compile|Liftoff|TurboFan|turboshaft|WasmFullDecoder|LazyCompile/.test(below)) add('user: V8 lazy compile of a wasm function (its first call)');
        else add(/Scaveng|Mark|Sweep|Heap|GC/.test(leaf) ? 'user: V8 GC' : 'user: wasm calls into V8 or workerd (imports, memory.grow)');
        continue;
      }
      const tier = /liftoff/.test(firstJs) ? ', Liftoff' : '';
      const n = names.get(k) ?? (/^wasm-function\[/.test(own) ? '' : own);
      if (/^roc_llvm_rc_/.test(n)) { add('user: wasm Roc refcount (incref, decref)'); continue; }
      if (/^roc__p/.test(n)) { add(`user: wasm Roc app code${tier}`); continue; }
      if (/^(dev_wrappers|list|str|utils|num|dict|sort|hash|dec|json|crypto|bitcode|roc_builtins)\./.test(n) || /^roc_builtins/.test(n)) { add('user: wasm Roc builtins (Str, List, Dict, numbers)'); continue; }
      if (firstRoc !== null && k >= firstRoc) { add(`user: wasm Roc code (app and builtins${tier})`); continue; }
      if (/alloc|Alloc|dealloc|realloc|smallFree|smallTake|release|taskOf|taskEnd|runGive|runTake|runFind|takeLow|freeOwner|adopt|poolGrow|smallGive|avail/.test(n)) add('user: wasm host allocator');
      else if (/check_heap|checkTables|constSum|sumBytes|sumConst|logOk/.test(n)) add('user: wasm host global check (check_heap)');
      else if (/fletcher|sumTask|sumAdopted/.test(n)) add('user: wasm host sums');
      else if (/cbor|Cbor/.test(n)) add('user: wasm host CBOR');
      else add(`user: wasm host other${n ? '' : ' (no name)'}`);
      continue;
    }
    const file = (/(\.roc-cfw\/[a-z-]+\.js|hooks\.js)/.exec(firstJs ?? '') ?? [])[1] ?? '?';
    if (/^JS:|^Builtin:|^BytecodeHandler:|^Stub:/.test(leaf)) add(`user: shim JS ${file.replace('.roc-cfw/', '')}`);
    else if (/Scaveng|MarkCompact|Marking|Sweep|::Heap::|heap::base|CppHeap/.test(leaf)) add('user: V8 GC');
    else if (/workerd::api|workerd::jsg|jsg::/.test(frames.slice(0, 8).join(' '))) add('user: workerd API called from JS (Request, Response, Headers, D1, Cache)');
    else add('user: V8 runtime (C++) called from JS');
  }
  return { total, rows: [...acc].sort((a, b) => b[1] - a[1]).map(([part, n]) => ({ part, msPerRequest: +((n * msPerSample) / requests).toFixed(3), pct: +((100 * n) / total).toFixed(1) })) };
}

function rootless(frames) {
  const s = frames.join(' ');
  if (/sqlite3/i.test(s)) return 'no JS on the stack: SQLite (D1)';
  if (/deflate|longest_match|compress_block|build_tree/.test(s)) return 'no JS on the stack: zlib (response gzip)';
  if (/Scaveng|MarkCompact|ConcurrentMark|Sweep/.test(s)) return 'no JS on the stack: V8 GC (worker threads)';
  if (/Compile|Liftoff|TurboFan|turboshaft|Pipeline|wasm::/.test(s)) return 'no JS on the stack: V8 compile (JS and wasm)';
  if (/^\[unknown\]|0xffffffff|entry_SYSCALL|syscall/.test(frames[0]) || /kernel/.test(s)) return 'no JS on the stack: kernel and syscalls';
  if (/kj::|capnp|HttpServer|tokio/.test(s)) return 'no JS on the stack: workerd I/O (HTTP, RPC, event loop)';
  return 'no JS on the stack: other';
}
