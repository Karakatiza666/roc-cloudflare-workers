// The CBOR bytes that the JS shim writes (js/values.js `pack`) for the wire probes of wire.roc.
// Usage: node research/cbor-0.5.0/js-bytes.mjs. One line for each case: the name and the bytes of the item (no tag 24).
import { pack, decode } from '../../js/values.js';

const cases = {
  real_int: { r: 3 },
  real_frac: { r: 2.5 },
  undef_opt: { a: undefined },
  big_float_int: { n: 2 ** 60 },
  neg_zero: { r: -0 },
  blob_arr: { b: [1, 2, 255] },
  bytes_u8: { b: new Uint8Array([1, 2]) },
  long_list: { xs: Array.from({ length: 30 }, (_, i) => i) },
  date: { t: new Date(1700000000000) },
  bool01: { a: 1 },
  nan: { r: NaN },
};
const hex = (u8) => '[' + Array.from(u8, (x) => '0x' + x.toString(16).padStart(2, '0')).join(', ') + ']';
for (const [k, v] of Object.entries(cases)) {
  const b = pack(v);
  const inner = b.subarray(b[2] < 0x58 ? 3 : b[2] === 0x58 ? 4 : 5);
  console.log(k, hex(inner));
}
// What JS reads from the bytes that roc-cbor 0.5.0 writes (the argument: hex text of the bytes).
if (process.argv[2]) {
  const u8 = Uint8Array.from(process.argv[2].match(/../g).map((h) => parseInt(h, 16)));
  console.log('decode', process.argv[2], '->', decode(u8));
}
