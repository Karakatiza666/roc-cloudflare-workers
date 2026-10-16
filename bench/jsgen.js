// Seeded random JS values that cross as a `Js` tree (J1 to J7), and mutations of their bytes. For the tests of
// the Zig codec (bench/cbor-wasm-test.mjs, bench/hd4-test.mjs).
export const rng = (seed) => () => {
  seed |= 0;
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
class Thing {}
// Objects that become a `Ref` (J7).
export const things = [new Thing(), new Thing(), () => 1];
// A random value: no BigInt above i64, no Map.
export function gen(r, depth = 0) {
  const pick = (n) => Math.floor(r() * n);
  const leaf = depth >= 6 || r() < 0.35;
  switch (pick(leaf ? 13 : 19)) {
    case 0: return undefined;
    case 1: return null;
    case 2: return r() < 0.5;
    case 3: return pick(48) - 24;
    case 4: return Math.round((r() - 0.5) * 2 ** (1 + pick(52)));
    case 5: return [0.5, -2.25, NaN, Infinity, -Infinity, 1e300, 5e-324, 1.1, 65504.5, 3.4e38][pick(10)] * (r() < 0.3 ? -1 : 1);
    case 6: return BigInt.asIntN(64, (BigInt(Math.floor(r() * 2 ** 32)) << 32n) | BigInt(Math.floor(r() * 2 ** 32)));
    case 7: return ['', 'a', 'key', 'x'.repeat(pick(300)), 'é'.repeat(pick(40)), '\u{1f600}'.repeat(pick(20)), '\ud800'][pick(7)];
    case 8: return Uint8Array.from({ length: pick(300) }, () => pick(256));
    case 9: return things[pick(things.length)];
    case 10: return new Error(['m', 'é', ''][pick(3)]);
    case 11: return new Date(Math.round((r() - 0.3) * 2 ** (30 + pick(20))));
    case 12: return -pick(2 ** 31) * pick(2 ** 20);
    case 13: case 14: case 15: return Array.from({ length: pick(30) }, () => gen(r, depth + 1));
    default: {
      const o = {};
      for (let i = pick(6); i > 0; i--) o[['a', 'b', 'id', 'name', 'é', 'long_key_' + pick(30)][pick(6)]] = gen(r, depth + 1);
      return o;
    }
  }
}
// 1 to 4 random changes: a byte set, a cut, a byte put in, a bit flipped.
export function mutate(r, b) {
  const pick = (n) => Math.floor(r() * n);
  for (let m = pick(4); m >= 0 && b.length > 0; m--) {
    const k = pick(4);
    if (k === 0) b[pick(b.length)] = pick(256);
    else if (k === 1) b = b.subarray(0, pick(b.length));
    else if (k === 2) b = Uint8Array.from([...b.subarray(0, pick(b.length)), pick(256), ...b.subarray(pick(b.length))]);
    else b[pick(b.length)] ^= 1 << pick(8);
  }
  return b;
}
