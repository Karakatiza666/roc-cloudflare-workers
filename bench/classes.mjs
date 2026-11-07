// The size classes and the span pages (hostlib/alloc.zig: classes near 4096 / k up to 2048 B, then 1 KB steps
// up to 8 KB in pages of several units). node bench/classes.mjs bench/out/alloc_driver.wasm
// 1. Class edges: a block of each class size takes that class, one byte more takes the next class
//    (live bytes), and 8193 B is a large block of 3 units. Blocks of one class are side by side in one page.
// 2. Span pages: the blocks of a span class fill the whole span (3072 B: 4 blocks in 3 units), the next block
//    goes to a new span. A block in a later unit of the span: free and realloc at a pointer in it work.
// 3. Realloc across the class edges, 100 B to 9000 B and back down: the bytes stay, the live bytes are the class up to
//    2048 B, then a large block of whole units (a growing block stays able to grow in place).
// 4. A task that frees all its blocks, and a task that ends with live blocks: live bytes 0, the spans go back
//    to the free runs (heap_used is only the page reserve), the global check passes.
// 5. Sums: a write in a later unit of a span of task 7 changes the sum of task 7; a write in a span of task 8 does not.
// 6. Owner check in a span: a stale free of a block in a later unit of a span that went to another task is a
//    miss (dealloc_miss), the block stays live.
// 7. Double free of a block in a span (the free list has more than one entry): caught, the live count stays.
// 8. A JS block in a later unit of a span: adopt, then freeOwner frees it.
// 9. The global check sees a span unit with a wrong kind or a wrong first unit.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const A = 1 | (16 << 8);
const R = 3 | (16 << 8);
const ALLOC = (owner, id, len) => [A, owner, id, len];
const FREE = (owner, id) => [2, owner, id, 0];
const SUM = (owner, id) => [5, owner, id, 0];
let ok = true;
const check = (pass, text) => {
  console.log(`${text}: ${pass ? 'ok' : 'FAIL'}`);
  if (!pass) ok = false;
};
const fresh = () => {
  const x = new WebAssembly.Instance(mod, {}).exports;
  const run = (...ops) => { new Uint32Array(x.memory.buffer, x.rec_buf(), ops.length * 4).set(ops.flat()); x.run(ops.length); };
  const bytes = (p, n) => new Uint8Array(x.memory.buffer, p, n);
  return { x, run, bytes };
};
const CH = 4096;
// The classes that the design gives (the test does not read them from the allocator).
const WANT = [16, 32, 48, 64, 96, 128, 192, 256, 288, 336, 400, 448, 512, 576, 672, 816, 1024, 1360, 2048, 3072, 4096, 5120, 6144, 7168, 8192];
const SPAN = { 3072: 3, 5120: 5, 6144: 3, 7168: 7, 8192: 2 };
const unitsOf = (c) => SPAN[c] ?? 1;

// 1 ---------------------------------------------------------------------------------------------
{
  const got = [];
  for (let i = 0; i < 64; i++) { const { x } = fresh(); if (x.class_size(i) === 0) break; got.push(x.class_size(i)); }
  check(got.join() === WANT.join(), `1. class table ${got.join(' ')}`);
  const bad = [];
  for (let i = 0; i < WANT.length; i++) {
    const c = WANT[i], next = WANT[i + 1] ?? 3 * CH;
    for (const [len, want] of [[c, c], [c + 1, next]]) {
      const { x, run } = fresh();
      run(ALLOC(7, 0, len), ALLOC(7, 1, len));
      const live = x.live_bytes();
      // Two blocks of a class: side by side in one page (a large block: its own units).
      const gap = x.ptr_of(1) - x.ptr_of(0);
      const side = want === 3 * CH ? true : (want * 2 > unitsOf(want) * CH ? true : gap === want);
      if (live !== 2 * want || !side || x.check_tables() !== 0) bad.push(`${len}: live ${live} (want ${2 * want}), gap ${gap}`);
    }
  }
  check(bad.length === 0, `1. each class edge c and c + 1 (${WANT.length * 2} sizes)${bad.length ? ' ' + bad.join('; ') : ''}`);
}

// 2 ---------------------------------------------------------------------------------------------
{
  const bad = [];
  for (const c of [3072, 5120, 6144, 7168, 8192]) {
    const { x, run, bytes } = fresh();
    const per = (unitsOf(c) * CH) / c;
    for (let i = 0; i <= per; i++) run(ALLOC(7, i, c - 8));
    const p0 = x.ptr_of(0);
    const inSpan = Array.from({ length: per }, (_, i) => x.ptr_of(i) === p0 + i * c).every(Boolean);
    const outside = x.ptr_of(per) < p0 || x.ptr_of(per) >= p0 + unitsOf(c) * CH;
    if (!inSpan || !outside || p0 % CH !== 0) bad.push(`${c}: in span ${inSpan}, next block outside ${outside}`);
    // The last block of the span starts in a later unit (when the span has more than one block).
    const last = per - 1;
    const p = x.ptr_of(last);
    bytes(p, c).fill(0x3c);
    // Realloc at a pointer inside it (offset 16) to a size that fits: same pointer.
    run([R | (16 << 16), 7, last, c - 16]);
    const same = x.ptr_of(last) === p;
    // Realloc to more than the class: the block moves, its bytes stay.
    run([R | (16 << 16), 7, last, c + 100]);
    // The driver keeps the pointer minus the offset: the block starts at ptr_of + 16.
    const moved = x.ptr_of(last) !== p && bytes(x.ptr_of(last) + 16, c - 16).every((b) => b === 0x3c);
    const live0 = x.live_bytes(), miss0 = x.dealloc_miss();
    run([2 | (16 << 16), 7, last, 0]);
    const freed = x.live_bytes() < live0 && x.dealloc_miss() === miss0;
    if (!same || !moved || !freed || x.check_tables() !== 0) bad.push(`${c}: realloc in place ${same}, moved with bytes ${moved}, freed ${freed}, check ${x.check_tables()}`);
  }
  check(bad.length === 0, `2. span classes fill the span; realloc and free at a pointer in a later unit${bad.length ? ' ' + bad.join('; ') : ''}`);
}

// 3 ---------------------------------------------------------------------------------------------
// A realloc that moves a block above 2048 B gives a large block (whole units, it can grow in place), not a span class.
{
  const { x, run, bytes } = fresh();
  const steps = [100, 1024, 1025, 1360, 1361, 2048, 2049, 3000, 4096, 4097, 9000, 8192, 3000, 2000, 100];
  const small = (n) => WANT.find((c) => c >= n);
  const units = (n) => Math.ceil(n / CH) * CH;
  run(ALLOC(7, 0, 50));
  bytes(x.ptr_of(0), 50).fill(0x5d);
  let len = 50, cap = 64;
  const bad = [];
  for (const n of steps) {
    const p = x.ptr_of(0), wasSmall = cap <= 2048, old = cap;
    run([R, 7, 0, n]);
    const moved = x.ptr_of(0) !== p;
    // Fits: it stays (a shrink too). Small and too short: it moves, to a class up to 2048 B, else to a large block.
    if (n > cap) cap = n <= 2048 ? small(n) : units(n);
    const kept = bytes(x.ptr_of(0), Math.min(len, n)).every((b) => b === 0x5d);
    if (n > len) bytes(x.ptr_of(0) + len, n - len).fill(0x5d);
    len = n;
    // A small block moves exactly when n is more than its class; a large block can also grow in place.
    const moveOk = wasSmall ? moved === n > old : !(n <= old && moved);
    if (!kept || !moveOk || x.live_bytes() !== cap || x.check_tables() !== 0)
      bad.push(`${n}: bytes kept ${kept}, moved ${moved}, live ${x.live_bytes()} (want ${cap}), check ${x.check_tables()}`);
  }
  run(FREE(7, 0));
  // A fresh block of the same sizes takes the span class.
  run(ALLOC(7, 1, 3000));
  const fresh3000 = x.live_bytes() === 3072;
  run(FREE(7, 1));
  check(bad.length === 0 && x.live_bytes() === 0 && fresh3000, `3. realloc across the edges (${steps.length} steps); a fresh 3000 B block is class 3072 ${fresh3000}; live at the end ${x.live_bytes()}${bad.length ? ' ' + bad.join('; ') : ''}`);
}

// 4 ---------------------------------------------------------------------------------------------
{
  const { x, run } = fresh();
  // The units by kind: 1 small page, 2 large, 3 large body, 5 span; 0 and not free: the page reserve.
  const kinds = () => {
    const k = new Uint8Array(x.memory.buffer, x.table_kind(), 32768), bits = new BigUint64Array(x.memory.buffer, x.table_free_bits(), 512);
    const n = { 1: 0, 2: 0, 3: 0, 5: 0, reserve: 0 };
    for (let u = x.pool_lo(); u < x.pool_hi(); u++) {
      const free = ((bits[u >> 6] >> BigInt(u & 63)) & 1n) === 1n;
      if (k[u] in n) n[k[u]]++;
      else if (k[u] === 0 && !free) n.reserve++;
    }
    return n;
  };
  const sizes = [20, 300, 700, 1100, 1500, 2500, 3500, 4500, 5500, 6500, 7500, 8100, 20000];
  const ops = [];
  for (let i = 0; i < 200; i++) ops.push(ALLOC(7, i, sizes[i % sizes.length]));
  run(...ops);
  const k0 = kinds(), chk0 = x.check_tables();
  run(...ops.map((op) => FREE(7, op[2])));
  const k1 = kinds();
  const freed = x.live_bytes() === 0 && k1[1] + k1[2] + k1[3] + k1[5] === 0 && x.heap_used() === k1.reserve * CH;
  run(...ops, [4, 7, 0, 0]);
  const k2 = kinds();
  const ended = x.live_bytes() === 0 && k2[1] + k2[2] + k2[3] + k2[5] === 0 && x.heap_used() === k2.reserve * CH;
  check(k0[5] > 0 && chk0 === 0 && freed && ended && x.check_tables() === 0,
    `4. ${k0[5]} span units in use; task frees all: ${JSON.stringify(k1)}, units in use ${x.heap_used() / CH}; task ends with blocks live: ${JSON.stringify(k2)}, check ${x.check_tables()}`);
}

// 5 ---------------------------------------------------------------------------------------------
{
  const { x, run, bytes } = fresh();
  run(ALLOC(7, 0, 5000), ALLOC(7, 1, 5000), ALLOC(7, 2, 5000), ALLOC(8, 3, 5000), ALLOC(8, 4, 1300), ALLOC(7, 5, 1300));
  run(SUM(7, 0));
  const s0 = x.sum_of(0);
  // Block 2 starts at 10240 B in the span: unit 3 of 5.
  const p = x.ptr_of(2) + 4000;
  const unitIn = (p >> 12) - (x.ptr_of(0) >> 12);
  bytes(p, 1)[0] ^= 0x40;
  run(SUM(7, 1));
  const s1 = x.sum_of(1);
  bytes(p, 1)[0] ^= 0x40;
  bytes(x.ptr_of(3) + 4900, 1)[0] ^= 0x40;
  bytes(x.ptr_of(4) + 1200, 1)[0] ^= 0x40;
  run(SUM(7, 2));
  const s2 = x.sum_of(2);
  bytes(x.ptr_of(5) + 1350, 1)[0] ^= 0x40;
  run(SUM(7, 3));
  const s3 = x.sum_of(3);
  check(unitIn >= 2 && s1 !== s0 && s2 === s0 && s3 !== s0,
    `5. sum of task 7: write in unit ${unitIn} of its span changes it ${s1 !== s0}; writes in task 8 blocks keep it ${s2 === s0}; write at byte 1350 of a 1360 block changes it ${s3 !== s0}`);
}

// 6 ---------------------------------------------------------------------------------------------
{
  const { x, run, bytes } = fresh();
  run(ALLOC(7, 0, 5000), ALLOC(7, 1, 5000), ALLOC(7, 2, 5000), FREE(7, 0), FREE(7, 1), FREE(7, 2));
  // The span went back; task 8 gets the same units.
  run(ALLOC(8, 10, 5000), ALLOC(8, 11, 5000), ALLOC(8, 12, 5000));
  const same = x.ptr_of(12) === x.ptr_of(2);
  bytes(x.ptr_of(12), 5000).fill(0x6e);
  const live0 = x.live_bytes(), miss0 = x.dealloc_miss();
  // Task 9 (another task) frees the stale pointer of block 2: a later unit of the span of task 8.
  run(ALLOC(9, 20, 30), FREE(9, 2));
  const kept = bytes(x.ptr_of(12), 5000).every((b) => b === 0x6e);
  check(same && x.live_bytes() === live0 + 32 && x.dealloc_miss() === miss0 + 1 && kept && x.check_tables() === 0,
    `6. stale free into a span of another task: same units ${same}, dealloc_miss ${miss0} -> ${x.dealloc_miss()}, live ${live0} -> ${x.live_bytes() - 32}, bytes kept ${kept}`);
}

// 7 ---------------------------------------------------------------------------------------------
{
  const { x, run } = fresh();
  run(ALLOC(7, 0, 3000), ALLOC(7, 1, 3000), ALLOC(7, 2, 3000), ALLOC(7, 3, 3000));
  // Free 3 then 2 (both in later units), then 3 again: 3 is the second entry of the free list.
  run(FREE(7, 3), FREE(7, 2));
  const live0 = x.live_bytes();
  run(FREE(7, 3));
  const caught = x.double_frees() === 1 && x.live_bytes() === live0;
  run(ALLOC(7, 4, 3000), ALLOC(7, 5, 3000), ALLOC(7, 6, 3000));
  const ptrs = [0, 1, 4, 5, 6].map((i) => x.ptr_of(i));
  check(caught && new Set(ptrs).size === 5 && x.check_tables() === 0,
    `7. double free in a span: caught ${x.double_frees()}, live kept ${x.live_bytes() >= live0}, later blocks differ ${new Set(ptrs).size === 5}`);
}

// 8 ---------------------------------------------------------------------------------------------
{
  const { x, run } = fresh();
  run(ALLOC(7, 0, 40), [8, 0, 1, 5000], [8, 0, 2, 5000], [8, 0, 3, 5000]);
  const inLater = (x.ptr_of(3) >> 12) !== ((x.ptr_of(1) - 8) >> 12);
  const base = x.live_bytes();
  run([6, 7, 3, 0]);
  run([9, 7, 0, 0]);
  check(inLater && x.live_bytes() === base - 48 - 5120 && x.check_tables() === 0,
    `8. JS block in a later unit of a span: adopted and freed by freeOwner (live ${base} -> ${x.live_bytes()})`);
}

// 9 ---------------------------------------------------------------------------------------------
{
  const bad = [];
  for (const [name, poke] of [
    ['kind', (k, s, h) => { k[h + 2] = 0; }],
    ['first unit', (k, s, h) => { s[h + 2] = h + 1; }],
  ]) {
    const { x, run } = fresh();
    run(ALLOC(7, 0, 5000));
    const h = x.ptr_of(0) >> 12;
    const before = x.check_tables();
    poke(new Uint8Array(x.memory.buffer, x.table_kind(), 32768), new Uint16Array(x.memory.buffer, x.table_start(), 32768), h);
    const after = x.check_tables();
    if (before !== 0 || after === 0) bad.push(`${name}: check ${before} -> ${after}`);
  }
  check(bad.length === 0, `9. global check sees a broken span unit${bad.length ? ' ' + bad.join('; ') : ''}`);
}

console.log(ok ? 'PASS classes' : 'FAIL classes');
process.exit(ok ? 0 : 1);
