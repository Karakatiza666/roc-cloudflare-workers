// Cost of memory.grow in V8 (node), by step, from 1 MB to 128 MB.
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
for (const pages of [1, 4, 16, 64]) {
  const runs = [];
  for (let r = 0; r < 7; r++) {
    const m = new WebAssembly.Memory({ initial: 16 });
    let n = 0; const t = performance.now();
    while (m.buffer.byteLength + pages * 65536 <= 128 * 1048576) { m.grow(pages); n++; }
    runs.push(((performance.now() - t) * 1000) / n);
  }
  console.log(JSON.stringify({ pages, usPerGrow: +med(runs).toFixed(2), all: runs.map((v) => +v.toFixed(2)) }));
}
