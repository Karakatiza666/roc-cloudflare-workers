// PLAN.md step 8g: the parts of one crossing, each timed alone against the wasm exports of the bench host (Node and
// workerd run the same code). `x`: the exports of the instance. `values`: `js/values.js`. `bridge`: `js/bridge.js`.
// `program`: `js/program.js`. `now`: a clock in ms. Everything is in microseconds for one call.
//   js encode tree     `writeResult` of `Limited(rows as arrays)`: what `D1.rows!` sends (JS tree to CBOR in wasm memory)
//   js encode packed   `writeResult` of `Packed(rows as objects)`: what `D1.all!` sends (typed CBOR)
//   zig decode tree    `cbor_check`: the Zig decode of the tree bytes into Roc values, then free (a host block, no task)
//   zig decode packed  `cbor_check` of the packed bytes (one byte string: a copy into a `List(U8)`)
//   program k ops      JS decode (`fromJs`), Zig decode (`cbor_check`), Zig decode and encode (`cbor_echo`), JS run
//                      (`runCall`), JS encode of a small result (`writeResult`)
const H = 'A'.repeat(44);
const COLS = ['grp', 'version', 'hash', 'url', 'published_at', 'log_index', 'yanked', 'provenance'];
export const rowArrays = (rows) => Array.from({ length: rows }, (_, i) => ['roc-lang/http', `1.${i}.0`, H, `https://github.com/roc-lang/http/releases/download/1.${i}.0/${H}.tar.zst`, 1760000000 + i, 184000 + i, 0, '{"workflow":"release.yml"}']);
export const rowObjects = (rows) => rowArrays(rows).map((r) => Object.fromEntries(COLS.map((c, i) => [c, r[i]])));
export const COLUMNS = COLS;

export function makeParts({ x, values, bridge, program, now }) {
  const { Limited, Packed, Refs, toJs, fromJs } = values;
  const median = (xs) => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];
  // Microseconds of one call: the loop grows until a round takes 20 ms, then 9 rounds, the median (and the spread).
  const time = (f) => {
    let n = 1;
    for (;;) {
      const t0 = now();
      for (let i = 0; i < n; i++) f();
      if (now() - t0 >= 20 || n >= 1 << 24) break;
      n *= 2;
    }
    const rounds = [];
    for (let r = 0; r < 9; r++) {
      const t0 = now();
      for (let i = 0; i < n; i++) f();
      rounds.push(((now() - t0) / n) * 1000);
    }
    return { us: Math.round(median(rounds) * 1000) / 1000, min: Math.round(Math.min(...rounds) * 1000) / 1000, max: Math.round(Math.max(...rounds) * 1000) / 1000, n };
  };
  const out = x.js_alloc(8);
  // The bytes that `writeResult` writes for `value` (a copy), and the time of the write.
  const written = (value) => {
    const refs = new Refs();
    const st = bridge.writeResult(x, out, 0, value, refs);
    if (st !== 0) throw new Error(`writeResult: status ${st}`);
    const dv = new DataView(x.memory.buffer);
    const p = dv.getUint32(out, true);
    const len = dv.getUint32(out + 4, true);
    const bytes = new Uint8Array(x.memory.buffer, p, len).slice();
    x.res_free(p);
    return bytes;
  };
  const encodeTime = (value) =>
    time(() => {
      const st = bridge.writeResult(x, out, 0, value, new Refs());
      x.res_free(new DataView(x.memory.buffer).getUint32(out, true));
      if (st !== 0) throw new Error('status');
    });
  // The Zig decode of `bytes` (cbor_check) or decode and encode (cbor_echo). The block is freed at the end.
  const inBlock = (bytes, f) => {
    const p = x.js_alloc(bytes.length);
    new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
    try {
      return f(p, bytes.length);
    } finally {
      x.res_free(p);
    }
  };
  const zigDecode = (bytes) =>
    inBlock(bytes, (p, n) => {
      if (x.cbor_check(p, n) !== 0) throw new Error('cbor_check failed');
      return time(() => x.cbor_check(p, n));
    });
  const zigEcho = (bytes) =>
    inBlock(bytes, (p, n) =>
      time(() => {
        const b = x.cbor_echo(p, n);
        if (!b) throw new Error('cbor_echo failed');
        x.res_free(b);
      }),
    );

  return {
    rows(rows) {
      const arrays = rowArrays(rows);
      const tree = [COLS, ...arrays];
      const treeBytes = written(new Limited(tree, 1e9));
      const packedBytes = written(new Packed(rowObjects(rows), 1e9));
      return {
        rows,
        tree_bytes: treeBytes.length,
        packed_bytes: packedBytes.length,
        js_encode_tree: encodeTime(new Limited(tree, 1e9)),
        js_encode_packed: encodeTime(new Packed(rowObjects(rows), 1e9)),
        // The same with the rows made once: what D1 gives (JS objects) is made by D1, not by the shim.
        js_encode_packed_made: (() => {
          const objs = rowObjects(rows);
          return encodeTime(new Packed(objs, 1e9));
        })(),
        zig_decode_tree: zigDecode(treeBytes),
        zig_decode_packed: zigDecode(packedBytes),
      };
    },
    program(k) {
      const op = ['call', ['root', 'global'], 'isFinite', [['lit', 1]]];
      const prog = Array.from({ length: k }, () => op);
      const bytes = written(prog);
      const ctx = { roots: { global: globalThis }, refs: new Refs(), signal: undefined };
      const refs = new Refs();
      return {
        k,
        bytes: bytes.length,
        js_decode: time(() => fromJs(bytes, refs)),
        zig_decode: zigDecode(bytes),
        zig_decode_encode: zigEcho(bytes),
        js_run: time(() => program.runCall(prog, ctx)),
        js_encode_result: encodeTime(true),
      };
    },
  };
}
