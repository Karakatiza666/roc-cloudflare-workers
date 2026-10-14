import { readFileSync } from 'node:fs';
const { instance } = await WebAssembly.instantiate(readFileSync('c.wasm'));
const x = instance.exports; x.fill();
const n = 1 << 20;
const m = new BigUint64Array(x.memory.buffer, x.base(), n / 8);
for (const f of ['xorv', 'fletch', 'wy']) {
  const h0 = x[f](n);
  x.flip(12345); const flip = x[f](n) !== h0; x.flip(12345);
  if (m[128] === m[129]) throw new Error('same words');
  x.swap(1024, 1032); const swapNear = x[f](n) !== h0; x.swap(1024, 1032);
  x.swap(1024, 1040); const swapLane = x[f](n) !== h0; x.swap(1024, 1040);
  // Same delta added to one word and taken from another (cancels in a plain sum).
  m[200] += 5n; m[300] -= 5n; const cancel = x[f](n) !== h0; m[200] -= 5n; m[300] += 5n;
  // The same value written to two words in the same lane (cancels in XOR).
  const a = m[200], b = m[202]; m[200] ^= 0xffn; m[202] ^= 0xffn; const xor2 = x[f](n) !== h0; m[200] = a; m[202] = b;
  console.log(f.padEnd(6), { flip, swapNear, swapLane, sumCancel: cancel, xorCancel: xor2, restored: x[f](n) === h0 });
}
