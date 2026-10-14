// node q7.mjs: ns per sync JS import call from wasm, per memory.grow of 1 page, and per empty loop step (V8 in node).
const leb = (n) => { const b = []; do { let x = n & 0x7f; n >>>= 7; if (n) x |= 0x80; b.push(x); } while (n); return b; };
const sec = (id, c) => [id, ...leb(c.length), ...c];
const str = (s) => [s.length, ...Buffer.from(s)];
// Body: while (n) { acc += <op>; n-- } return acc. <op> pushes one i32.
const loop = (op) => { const b = [1, 1, 0x7f, 0x02, 0x40, 0x03, 0x40, 0x20, 0, 0x45, 0x0d, 1, 0x20, 1, ...op, 0x6a, 0x21, 1, 0x20, 0, 0x41, 1, 0x6b, 0x21, 0, 0x0c, 0, 0x0b, 0x0b, 0x20, 1, 0x0b]; return [...leb(b.length), ...b]; };
const bytes = Uint8Array.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
  ...sec(1, [2, 0x60, 0, 1, 0x7f, 0x60, 1, 0x7f, 1, 0x7f]),
  ...sec(2, [1, ...str('env'), ...str('f'), 0, 0]),
  ...sec(3, [3, 1, 1, 1]),
  ...sec(5, [1, 0, 1]),
  ...sec(7, [3, ...str('calls'), 0, 1, ...str('grows'), 0, 2, ...str('empty'), 0, 3]),
  ...sec(10, [3, ...loop([0x10, 0]), ...loop([0x41, 1, 0x40, 0]), ...loop([0x41, 1])])]);
let budget = 1 << 30, pages = 1;
// What js_grow would do: compare with the budget, count, answer yes.
const f = () => { if (pages + 1 > budget) return 0; pages++; return 1; };
const { exports: e } = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env: { f } });
const time = (fn, n) => { fn(n); const t = process.hrtime.bigint(); fn(n); return Number(process.hrtime.bigint() - t) / n; };
const N = 10_000_000;
const empty = time(e.empty, N), calls = time(e.calls, N);
// memory.grow: fresh instances, 2000 grows of 1 page each (128 MB total), 5 runs.
const g = [];
for (let r = 0; r < 5; r++) { const x = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env: { f } }); const t = process.hrtime.bigint(); x.exports.grows(2000); g.push(Number(process.hrtime.bigint() - t) / 2000); }
g.sort((a, b) => a - b);
console.log({ node: process.version, nsEmptyStep: +empty.toFixed(2), nsImportCall: +(calls - empty).toFixed(2), nsGrow1Page_median: Math.round(g[2]), nsGrow1Page_all: g.map(Math.round) });
