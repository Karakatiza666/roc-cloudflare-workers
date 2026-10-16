// API.md HD4: a differential test of the Zig decoder (wasm32 host, bench export `cbor_echo`) against the Roc
// oracle `bench/hd4/oracle.roc`. The same inputs go to both. Both must give a value with the same bytes
// (decode, then encode again), or both an error.
// node bench/hd4-test.mjs bench/out/app.wasm   Env: ROC (default: bench/get-roc.sh). Exit 1 on a failure.
// Inputs: every input of 1 and 2 bytes, edge cases of the profile, random values, mutated and cut values.
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { makeRunner } from './core.js';
import { toJs, Refs } from '../js/values.js';
import { rng, gen, mutate } from './jsgen.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const x = makeRunner(module, async () => '', { isolateBytes: 2 ** 40 }).x;
const roc = process.env.ROC || execFileSync('bench/get-roc.sh', { encoding: 'utf8' }).trim();
const H = (s) => Uint8Array.from(Buffer.from(s.replace(/\s/g, ''), 'hex'));

const inputs = [];
// Every input of 1 and 2 bytes.
for (let a = 0; a < 256; a++) {
  inputs.push(Uint8Array.of(a));
  for (let b = 0; b < 256; b++) inputs.push(Uint8Array.of(a, b));
}
// Edge cases: integer range, widths, floats, UTF-8, tags 24 and 27, depth, lengths, trailing bytes.
const nest = (k, head) => Uint8Array.from([...new Array(k).fill(head), 0x01]);
const nestMap = (k) => Uint8Array.from([...new Array(k).fill([0xa1, 0x61, 0x6b]).flat(), 0x01]);
[
  '1b7fffffffffffffff', '1b8000000000000000', '3b7fffffffffffffff', '3b8000000000000000', '1bffffffffffffffff',
  '1800', '190001', '1a00000001', '1b0000000000000001', '3800', '5800', '7800', '9800', 'b800',
  'f90000', 'f98000', 'f90001', 'f983ff', 'f903ff', 'f93c00', 'f97bff', 'f97c00', 'f9fc00', 'f97e00', 'f97c01', 'f9ffff',
  'fa00000001', 'fa7f800000', 'fa7fc00000', 'fa7f800001', 'faff7fffff', 'fb7ff8000000000001', 'fbfff0000000000000', 'fb8000000000000000',
  '62c380', '62c3', '61ff', '62c080', '63eda080', '63edbfbf', '64f4908080', '64f48fbfbf', '63e08080', '66f09f9880f0',
  'd81840', 'd8184100', 'd81843010203', 'd81860', 'd818f6', 'd9001841ff', 'da0000001841ff', 'd81b8263526566 01', 'd81b8263526566 1affffffff',
  'd81b8263526566 1b0000000100000000', 'd81b8263526566 20', 'd81b8363526566 01 01', 'd81b8265 4572726f72 61 61', 'd81b83654572726f72 61 61 61 62',
  'd81b83654572726f72 01 6162', 'd81b83654572726f72 6161 6262', 'd81b83654572726f72 6161', 'd81b8262526566 01', 'd81b826352656601 00',
  'd81b9802 63526566 01', 'd901b8 01', 'c0 01', 'd81a 01', 'd81bf6', 'd81b8463526566 01 01 01',
  '9fff', '5fff', '7fff', 'bfff', 'ff', '1c', '1d', '1e', '1f', 'f800', 'f818', 'f8ff', 'e0', 'f0', 'f3', 'fc', 'fd', 'fe',
  'a1 01 01', 'a1 41 61 01', 'a2 6161 01 6161 02', 'a1 6161', '82 01', '8201 02 03', '5a ffffffff', '9b ffffffffffffffff 01',
  'bb ffffffffffffffff 01', '7a 00000002 6162', '41', '',
].forEach((h) => inputs.push(H(h)));
for (const k of [63, 64, 65, 66]) inputs.push(nest(k, 0x81), nestMap(k), nest(k, 0x9f));
// Random values, as JS writes them, and mutated and cut copies.
const r = rng(4004), pick = (n) => Math.floor(r() * n);
const refs = new Refs();
for (let i = 0; i < 4000; i++) {
  const b = Uint8Array.from(toJs(gen(r), refs));
  inputs.push(b);
  for (let k = 0; k < 4; k++) inputs.push(mutate(r, Uint8Array.from(b)));
  if (b.length < 40) for (let k = 0; k < b.length; k++) inputs.push(b.subarray(0, k));
}
for (let i = 0; i < 5000; i++) inputs.push(Uint8Array.from({ length: 1 + pick(24) }, () => pick(256)));

// The Zig result of each input: decode, then encode again (cbor_echo), or an error.
const u32 = (n) => Uint8Array.of(n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24);
const corpus = [], zig = [];
let zigValues = 0;
for (const b of inputs) {
  corpus.push(u32(b.length), b);
  const p = b.length ? x.js_alloc(b.length) : 0;
  if (b.length) new Uint8Array(x.memory.buffer, p, b.length).set(b);
  const e = x.cbor_echo(p, b.length);
  if (p) x.res_free(p);
  if (e) {
    const len = new DataView(x.memory.buffer).getUint32(e, true);
    zig.push(Uint8Array.of(1), u32(len), new Uint8Array(x.memory.buffer, e + 4, len).slice());
    x.res_free(e);
    zigValues++;
  } else zig.push(Uint8Array.of(0), u32(0));
}
writeFileSync('bench/hd4/corpus.bin', Buffer.concat(corpus));
writeFileSync('bench/hd4/zig.bin', Buffer.concat(zig));
console.log(`${inputs.length} inputs; the Zig decoder gives ${zigValues} values and ${inputs.length - zigValues} errors`);

const out = execFileSync(roc, ['bench/hd4/oracle.roc'], { encoding: 'utf8', maxBuffer: 1 << 24 });
process.stdout.write(out);
const last = out.trim().split('\n').at(-1);
const ok = last.startsWith('PASS') && last.includes(` ${inputs.length} inputs`) && x.live_bytes() === 0;
console.log(ok ? 'PASS' : `FAIL (live bytes ${x.live_bytes()})`);
process.exit(ok ? 0 : 1);
