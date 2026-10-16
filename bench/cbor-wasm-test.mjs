// PLAN.md 8a, phase 2: the Zig codec in the wasm32 host (bench exports `cbor_check`, `cbor_echo`).
// node bench/cbor-wasm-test.mjs bench/out/app.wasm
//   HD5   seeded random, mutated and cut inputs: a value or a fault number (1 to 11), never a trap.
//   HD6   10,000 decodes of a large value: the live bytes go back to the start value.
//   same  for a set of fixtures and 5,000 random values, the Zig bytes (decode, encode) equal the JS bytes.
// Exit 1 on a failure.
import { readFileSync } from 'node:fs';
import { makeRunner } from './core.js';
import { toJs, fromJs, Refs } from '../js/values.js';
import { rng, gen, things, mutate } from './jsgen.js';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const r = makeRunner(module, 'b', async () => '', { isolateBytes: 2 ** 40 });
const x = r.x;
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const hex = (b) => Buffer.from(b).toString('hex');
const FAULTS = 11;

// The bytes in a js_alloc block, then `f(p, len)`, then the block is freed.
function withBlock(bytes, f) {
  const p = bytes.length ? x.js_alloc(bytes.length) : 0;
  if (bytes.length && !p) throw new Error('js_alloc gave 0');
  if (bytes.length) new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
  try {
    return f(p, bytes.length);
  } finally {
    if (p) x.res_free(p);
  }
}
const check = (bytes) => withBlock(bytes, (p, n) => x.cbor_check(p, n));
// The Zig bytes of a value: decode, then encode. null: not a value.
const echo = (bytes) =>
  withBlock(bytes, (p, n) => {
    const b = x.cbor_echo(p, n);
    if (!b) return null;
    const len = new DataView(x.memory.buffer).getUint32(b, true);
    const out = new Uint8Array(x.memory.buffer, b + 4, len).slice();
    x.res_free(b);
    return out;
  });

const live0 = x.live_bytes();

// ---- same bytes in Zig and JS: fixtures (API.md 5, HD7 shapes), then random values.
{
  const refs = new Refs();
  const deep = (n) => (n === 0 ? 1 : [deep(n - 1)]);
  const fixtures = [
    undefined, null, true, false, 0, 1, -1, 23, 24, 255, 256, 65535, 65536, 2 ** 32 - 1, 2 ** 32, -(2 ** 53),
    2n ** 63n - 1n, -(2n ** 63n), 0.5, -0.0, 1.5e300, NaN, Infinity, -Infinity, '', 'a', 'é\u{1f600}', 'x'.repeat(70000),
    new Uint8Array(0), Uint8Array.from([1, 2, 3]), new Uint8Array(70000), [], [1, [2, [3]]], {}, { a: 1, b: [null, undefined] },
    new Error('boom'), new TypeError('bad'), things[0], [things[0], things[1], things[0]], deep(63),
    { rows: Array.from({ length: 200 }, (_, i) => ({ id: i, name: `row ${i}`, ok: i % 2 === 0, at: i * 0.25 })) },
  ];
  let n = 0;
  for (const v of fixtures) {
    const js = toJs(v, refs).slice();
    const zig = echo(js);
    if (zig === null || hex(zig) !== hex(js)) fail(`same bytes: fixture ${n}: JS ${hex(js).slice(0, 60)} Zig ${zig && hex(zig).slice(0, 60)}`);
    n++;
  }
  // The Packed of a value: the content is not read, and comes back the same.
  const packed = toJs(fixtures.at(-1), refs);
  const zigPacked = echo(packed);
  if (!zigPacked || hex(zigPacked) !== hex(packed)) fail('same bytes: a large tree');
  const r1 = rng(8001);
  for (let i = 0; i < 5000; i++) {
    const js = toJs(gen(r1, 0), refs).slice();
    const zig = echo(js);
    if (zig === null || hex(zig) !== hex(js)) {
      fail(`same bytes: random ${i}: JS ${hex(js).slice(0, 80)} Zig ${zig && hex(zig).slice(0, 80)}`);
      break;
    }
    // And JS reads the Zig bytes back to the same bytes.
    if (hex(toJs(fromJs(zig, refs), refs)) !== hex(js)) {
      fail(`same bytes: JS of Zig bytes, random ${i}`);
      break;
    }
    n++;
  }
  console.log(`same bytes: ${n} values (${fixtures.length} fixtures)`);
}

// ---- HD5: random, mutated and cut inputs. Each is a value (0) or one fault (1 to 11). A trap throws here.
{
  const r2 = rng(5005), pick = (k) => Math.floor(r2() * k);
  const refs = new Refs();
  const byFault = new Array(FAULTS + 1).fill(0);
  let inputs = 0;
  const one = (b) => {
    let code;
    try {
      code = check(b);
    } catch (e) {
      fail(`HD5: a trap for ${hex(b).slice(0, 80)}: ${e}`);
      return;
    }
    if (!(code >= 0 && code <= FAULTS)) fail(`HD5: code ${code} for ${hex(b).slice(0, 80)}`);
    else byFault[code]++;
    inputs++;
  };
  for (let i = 0; i < 20000; i++) {
    let b = Uint8Array.from(toJs(gen(r2, 0), refs));
    if (i % 4 === 0) {
      // Every prefix of a small value: each one is cut (fault 1) or a shorter value.
      if (b.length < 64) for (let k = 0; k < b.length; k++) one(b.subarray(0, k));
      continue;
    }
    b = mutate(r2, b);
    one(b);
  }
  // Pure random bytes.
  for (let i = 0; i < 20000; i++) one(Uint8Array.from({ length: 1 + pick(40) }, () => pick(256)));
  // Deep nesting: 65 levels is fault 10, 64 is a value.
  const nest = (k) => Uint8Array.from([...new Array(k).fill(0x81), 0x01]);
  if (check(nest(64)) !== 0) fail('HD5: 64 levels must decode');
  if (check(nest(65)) !== 10) fail(`HD5: 65 levels must be the depth fault, got ${check(nest(65))}`);
  if (check(nest(100000)) !== 10) fail('HD5: 100,000 levels must be the depth fault');
  console.log(`HD5: ${inputs} inputs; values and faults by number:`, byFault.join(' '));
  if (byFault[0] < 1000 || byFault.slice(1).filter((c) => c > 0).length < 6) fail('HD5: the corpus does not reach enough faults');
}

// ---- HD6: 10,000 decodes of a large value (lists, records, text, bytes, refs) leave no live bytes.
{
  const refs = new Refs();
  const big = toJs({ rows: Array.from({ length: 50 }, (_, i) => ({ id: i, s: 'text '.repeat(i), b: new Uint8Array(i), t: things[i % 2], e: new Error('e') })) }, refs).slice();
  const before = x.live_bytes();
  withBlock(big, (p, n) => {
    for (let i = 0; i < 10000; i++) {
      let c;
      try {
        c = x.cbor_check(p, n);
      } catch (e) {
        fail(`HD6: decode ${i} trapped (a leak fills the heap): ${e}`);
        break;
      }
      if (c !== 0) {
        fail(`HD6: decode ${i} gave fault ${c}`);
        break;
      }
    }
  });
  const after = x.live_bytes();
  console.log(`HD6: live bytes ${before} before, ${after} after 10,000 decodes of ${big.length} B`);
  if (after !== before) fail(`HD6: ${after - before} live bytes after 10,000 decodes`);
}

const live1 = x.live_bytes();
if (live1 !== live0) fail(`live bytes ${live0} at the start, ${live1} at the end`);
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
