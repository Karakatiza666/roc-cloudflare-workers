// PLAN.md 6d and 2d on the allocator driver: node bench/oomclean.mjs bench/out/alloc_driver.wasm
// A failed `roc_alloc` or `roc_realloc` traps, and the trap is clean while a task runs
// (owner 7). With no task (owner 0, a host call from JS) the trap is not clean.
import { readFileSync } from 'node:fs';
const x = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(process.argv[2])), {}).exports;
x.set_free_mark((crypto.getRandomValues(new Uint32Array(1))[0] | 1) >>> 0);
const run = (ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
const al = 8 << 8;
// Returns what the call did: 'traps' or 'returns'.
const attempt = (ops) => { try { run(ops); return 'returns'; } catch (e) { return e instanceof WebAssembly.RuntimeError ? 'traps' : String(e); } };
let ok = true;
const row = (name, got, want) => { const pass = got === want; if (!pass) ok = false; console.log(`${name}: ${got} (want ${want}): ${pass ? 'ok' : 'FAIL'}`); };
// A block for each owner: a realloc of a block of another owner is a miss (the owner check).
run([[1 | al, 7, 0, 24], [1 | al, 0, 2, 24]]);
for (const [owner, clean, blk] of [[7, 1, 0], [0, 0, 2]]) {
  x.clear_trap_clean();
  run([[12, 0, 0, 0]]);
  row(`roc_alloc fails, owner ${owner}`, attempt([[10 | al, owner, 1, 64]]), 'traps');
  row(`  trap clean`, x.trap_clean(), clean);
  x.clear_trap_clean();
  run([[12, 0, 0, 0]]);
  // 24 B to 5,000 B: the block moves, so the new block is allocated.
  row(`roc_realloc fails, owner ${owner}`, attempt([[11 | al, owner, blk, 5000]]), 'traps');
  row(`  trap clean`, x.trap_clean(), clean);
}
// The flag is used once: the next calls work.
x.clear_trap_clean();
row('next roc_alloc', attempt([[10 | al, 7, 1, 64]]), 'returns');
row('next roc_realloc', attempt([[11 | al, 7, 0, 5000]]), 'returns');
console.log(ok ? 'PASS oomclean' : 'FAIL oomclean');
process.exit(ok ? 0 : 1);
