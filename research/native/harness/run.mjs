// Tests of the Native ops in wasm32 with the real allocator (PLAN.md 8e). Usage: node run.mjs [wasm file]
// Prints PASS or FAIL for each check. Exit code 1 when one fails.
import crypto from 'node:crypto';
import { load, data, le32, OP } from './lib.mjs';

const file = process.argv[2] || 'native-small.wasm';
const w = await load(file);
let failed = 0;
function check(name, ok, info = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${info ? '  ' + info : ''}`);
  if (!ok) failed++;
}
const eq = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0;
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

// W1: the bytes equal `zstd -d`
{
  const want = data('pkg.tar');
  for (const n of ['pkg.tar.zst', 'pkg-pipe.tar.zst', 'pkg-nocheck.tar.zst', 'pkg-w24.tar.zst']) {
    w.task(1);
    const r = w.call(OP.zstd_decode, Buffer.concat([le32(1 << 20), data(n)]));
    check(`W1 zstd_decode ${n} equals zstd -d`, r.status === 0 && eq(r.bytes, want));
    w.x.h_end_trap(1);
  }
  {
    w.task(1);
    const z = data('roc-parser.tar.zst');
    const r = w.call(OP.zstd_decode, Buffer.concat([le32(1 << 22), z]));
    w.x.h_end_trap(1);
    const want = data('roc-parser.sha256').toString().trim();
    check('W1 zstd_decode roc-parser.tar.zst (made by roc bundle) equals zstd -d', r.status === 0 && sha(r.bytes) === want);
    const res = [1, 7, 4096, 65536].map((c) => { const q = w.streamAll(1, z, c); w.x.h_end_trap(1); return q.bytes && sha(q.bytes) === want; });
    check('W4 stream of roc-parser.tar.zst, chunks 1, 7, 4096, 65536: same bytes as zstd -d', res.every(Boolean), res.join(','));
  }
  w.task(1);
  const m = w.call(OP.zstd_decode, Buffer.concat([le32(1 << 20), data('multi.zst')]));
  check('W1 zstd_decode multi.zst (2 frames and a skippable frame)', m.status === 0 && eq(m.bytes, data('multi.tar')));
  w.x.h_end_trap(1);
}

// W2: a small archive that decodes to more than the limit stops at the limit; the memory peak stays near the limit
for (const n of ['zeros.zst', 'zeros-pipe.zst']) {
  const limit = 256 << 10;
  w.task(1);
  w.x.h_peak_reset();
  const base = w.x.h_live();
  const r = w.call(OP.zstd_decode, Buffer.concat([le32(limit), data(n)]));
  const peak = w.x.h_peak() - base;
  w.x.h_end_trap(1);
  check(`W2 ${n} (${data(n).length} B, 4 MB out) with limit 256 KB: status 1 output_limit`, r.status === 1 && w.code(r) === 'output_limit');
  check(`W2 ${n}: peak memory ${(peak / 1024) | 0} KB <= 2 * (limit + 128 KB)`, peak <= 2 * (limit + 131072), `peak ${peak}`);
}
{
  w.task(1);
  w.x.h_peak_reset();
  const base = w.x.h_live();
  const r = w.call(OP.zstd_decode, Buffer.concat([le32(8 << 20), data('zeros-pipe.zst')]));
  const peak = w.x.h_peak() - base;
  w.x.h_end_trap(1);
  check('W2 with a big enough limit: the 4 MB output is right', r.status === 0 && r.bytes.length === (4 << 20) && sha(r.bytes) === data('zeros.sha256').toString().trim());
  console.log(`      (peak memory with no stop: ${(peak / 1024) | 0} KB)`);
}

// W3: a handle of another task gives status 1; the owner still can use it
{
  w.task(7);
  const h = w.handle(w.call(OP.blake3_new));
  const zh = w.handle(w.call(OP.zstd_stream_open));
  w.task(8);
  const codes = [];
  for (const [op, hh] of [[OP.blake3_update, h], [OP.blake3_final, h], [OP.zstd_stream_push, zh], [OP.zstd_stream_close, zh]]) {
    const r = w.call(op, Buffer.concat([le32(hh), Buffer.from('x')]));
    codes.push(r.status === 1 && w.code(r) === 'wrong_task');
  }
  check('W3 another task: update, final, push, close all give status 1 wrong_task', codes.every(Boolean));
  w.task(7);
  check('W3 the owner can use its handle', w.call(OP.blake3_update, Buffer.concat([le32(h), Buffer.from('x')])).status === 0);
  w.x.h_end_trap(7); w.x.h_end_trap(8);
}

// W4: chunk sizes 1, 7, 4096, 65536 give the same bytes
{
  const z = data('pkg.tar.zst'), want = data('pkg.tar');
  const res = [1, 7, 4096, 65536].map((c) => { const r = w.streamAll(1, z, c); w.x.h_end_trap(1); return r.bytes && eq(r.bytes, want); });
  check('W4 stream, chunks 1, 7, 4096, 65536: same bytes as zstd -d', res.every(Boolean), res.join(','));
}

// W5: digests in chunks equal the references (hashes.txt: sha256sum, python blake3)
for (const line of data('hashes.txt').toString().trim().split('\n')) {
  const [name, b3, s256] = line.split(' ');
  const buf = data(name);
  for (const chunk of [65536, 1000]) {
    const a = w.hashChunks(1, 'blake3', buf, chunk), b = w.hashChunks(1, 'sha256', buf, chunk);
    w.x.h_end_trap(1);
    check(`W5 ${name} (${buf.length} B) chunk ${chunk}: blake3 and sha256 equal the references`, a === b3 && b === s256);
  }
}

// W6: the memory of a task is freed at its end (return, trap, cancel), and only that task's handles go
{
  const z = data('pkg-pipe.tar.zst');
  w.x.h_peak_reset();
  const base = w.x.h_live();
  w.task(11);
  const zh = w.handle(w.call(OP.zstd_stream_open));
  w.call(OP.zstd_stream_push, Buffer.concat([le32(zh), z.subarray(0, 20000)]));
  w.handle(w.call(OP.blake3_new)); w.handle(w.call(OP.sha256_new));
  w.task(12);
  const other = w.handle(w.call(OP.blake3_new));
  w.call(OP.blake3_update, Buffer.concat([le32(other), Buffer.from('hello ')]));
  const held = w.x.h_live() - base;
  check('W6 task 11 holds handles and memory', w.x.h_in_use(11) === 3 && held > 0, `${held} B`);
  const freed = w.x.h_end_trap(11);
  check('W6 trap of task 11: its handles are gone, its memory is freed', w.x.h_in_use(11) === 0 && freed > 0, `freed ${freed} B`);
  check('W6 the handle of task 12 is still good, and gives the right digest', (() => {
    w.task(12);
    w.call(OP.blake3_update, Buffer.concat([le32(other), Buffer.from('world')]));
    const d = w.call(OP.blake3_final, le32(other)).bytes.toString('hex');
    return d === w.hashChunks(13, 'blake3', Buffer.from('hello world'), 4);
  })());
  w.x.h_end_done(13);
  const leakBefore = 0;
  w.task(14);
  w.handle(w.call(OP.sha256_new));
  const n = w.x.h_end_done(14);
  w.x.h_end_trap(12);
  check('W6 end of a task by return with a handle left: freed (counted as a leak of the app)', n > 0);
  check('W6 all memory back, no table error, no foreign free', w.x.h_live() === base && w.x.h_check() === 0 && w.x.h_miss() === 0,
    `live ${w.x.h_live() - base}, check ${w.x.h_check()}, miss ${w.x.h_miss()}`);
  // The old handle of task 11 is bad, for any task
  w.task(11);
  const r = w.call(OP.zstd_stream_close, le32(zh));
  check('W6 the handle of the ended task is bad (status 1)', r.status === 1 && w.code(r) === 'bad_handle');
  w.x.h_end_trap(11);
}

console.log(failed ? `\n${failed} FAILED` : '\nall passed');
process.exit(failed ? 1 : 0);
