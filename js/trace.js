// The trace of allocator calls (trace host: `zig build -Dtrace=true`, never the release build). The host calls
// `js_trace(op, owner, a, b, c)` at each top-level allocator call. This file keeps the records in the format of
// research/alloc/scripts/trace.mjs and research/alloc/scripts/replay.mjs:
//   4 x u32 per record: [op | align << 8 | offset << 16, owner, id, len]
//   ops: 1 alloc, 2 free, 3 realloc, 4 task end, 5 sum (wait), 6 adopt
//   offset: the pointer of a free or realloc minus the pointer that alloc gave. Ids are reused after a free.
// `take()` gives the records since the last `take` (the ids go on from chunk to chunk, so the chunks join).
export function makeTracer() {
  let buf = new Uint32Array(1 << 16);
  let n = 0;
  const ids = new Map();
  const freeIds = [];
  const stats = { nextId: 0, live: 0, maxLive: 0, misses: 0 };
  const put = (op, owner, id, len) => {
    if (n + 4 > buf.length) {
      const b = new Uint32Array(buf.length * 2);
      b.set(buf);
      buf = b;
    }
    buf[n++] = op;
    buf[n++] = owner;
    buf[n++] = id;
    buf[n++] = len;
  };
  const newId = (p) => {
    const id = freeIds.length ? freeIds.pop() : stats.nextId++;
    ids.set(p, id);
    if (++stats.live > stats.maxLive) stats.maxLive = stats.live;
    return id;
  };
  // A pointer inside a block: Roc and js_alloc can pass the block + 4.
  const find = (p) => {
    for (const d of [0, 4, 8, 12, 16]) if (ids.has(p - d)) return p - d;
    return -1;
  };
  // A free of a block that this trace did not see (a block of the host or of JS) is a miss, and it is not recorded.
  const hook = (op, owner, a, b, c) => {
    owner >>>= 0;
    a >>>= 0;
    b >>>= 0;
    c >>>= 0;
    const k = op & 0xff;
    if (k === 1) {
      if (c) put(op, owner, newId(c), b);
    } else if (k === 2) {
      const p = find(a);
      if (p < 0) {
        if (a) stats.misses++;
        return;
      }
      const id = ids.get(p);
      ids.delete(p);
      freeIds.push(id);
      stats.live--;
      put(2 | ((a - p) << 16), owner, id, 0);
    } else if (k === 3) {
      if (a === 0) {
        if (c) put(1 | (op & ~0xff), owner, newId(c), b);
        return;
      }
      const p = find(a);
      if (p < 0) {
        stats.misses++;
        return;
      }
      if (c === 0) return; // a failed realloc: the block stays
      const id = ids.get(p);
      ids.delete(p);
      ids.set(c, id);
      put(op | ((a - p) << 16), owner, id, b);
    } else if (k === 6) {
      const p = find(a);
      if (p < 0) {
        stats.misses++;
        return;
      }
      put(6, owner, ids.get(p), a - p);
    } else put(k, owner, 0, 0);
  };
  return {
    hook,
    stats,
    records: () => n / 4,
    take() {
      const out = buf.slice(0, n);
      n = 0;
      return out;
    },
  };
}
