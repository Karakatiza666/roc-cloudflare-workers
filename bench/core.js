// Runtime of the bench app, shared by the worker and the Node test.
// Variant "a": a new instance for each request. Variant "b": one shared
// instance, the host copies the shadow stack at each wait.
const dec = new TextDecoder();
const enc = new TextEncoder();

// The wait import (kinds as app/app.roc). It reads the arguments before its
// first await: in variant B they can be on the stack that others now use.
function makeWait(cell, io) {
  return async (kind, num, ap, al, bp, bl, cp, cl, out) => {
    const x = cell.x;
    const u8 = new Uint8Array(x.memory.buffer);
    const a = dec.decode(u8.subarray(ap, ap + al));
    const b = dec.decode(u8.subarray(bp, bp + bl));
    let status = 0;
    let body = new Uint8Array();
    try {
      body = enc.encode(await io(kind, a, b));
      status = 200;
    } catch {}
    const p = body.length ? x.js_alloc(body.length) : 0;
    const m = new Uint8Array(x.memory.buffer);
    if (p) m.set(body, p);
    const dv = new DataView(x.memory.buffer);
    dv.setUint32(out, p, true);
    dv.setUint32(out + 4, body.length, true);
    return status;
  };
}

function readRes(x, blk) {
  const len = new DataView(x.memory.buffer).getUint32(blk, true);
  const s = dec.decode(new Uint8Array(x.memory.buffer, blk + 4, len));
  x.res_free(blk);
  return s;
}

export function instanceA(module, io) {
  const cell = { x: null };
  const inst = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io)) } });
  cell.x = inst.exports;
  cell.x.init(0);
  return cell.x;
}

// A shared instance (variant B): the host copies the stack at each wait.
function instanceB(module, io) {
  const cell = { x: null };
  const inst = new WebAssembly.Instance(module, { env: { js_wait: new WebAssembly.Suspending(makeWait(cell, io)) } });
  const x = (cell.x = inst.exports);
  x.init(1);
  return { x, handle: WebAssembly.promising(x.handle) };
}

// run(req) -> { body, x } or { trap: message, x }. `x`: the instance that ran it.
// Variant "b" falls back to "a" when the module is not stack-first (`stack_first()`
// is 0): there a stack overflow can write over data, so an instance runs only
// one request. opts.noFallback keeps "b" (only for the overflow test).
export function makeRunner(module, variant, io, opts = {}) {
  const stats = { served: 0, traps: 0, freed: 0, walkFailed: 0, retired: 0, memBytes: 0, maxMemBytes: 0, fallback: false };
  const seen = (x) => {
    stats.memBytes = x.memory.buffer.byteLength;
    if (stats.memBytes > stats.maxMemBytes) stats.maxMemBytes = stats.memBytes;
  };
  let cur = variant === 'a' ? null : instanceB(module, io);
  if (cur && !cur.x.stack_first() && !opts.noFallback) {
    console.warn('module is not stack-first: one instance per request');
    stats.fallback = true;
    cur = null;
  }
  if (!cur) {
    return {
      stats,
      x: null,
      async run(req) {
        const x = instanceA(module, io);
        try {
          const blk = await WebAssembly.promising(x.handle)(...enc0(x, req));
          stats.served++;
          seen(x);
          this.x = x;
          return { body: readRes(x, blk), x };
        } catch (e) {
          stats.traps++;
          seen(x);
          this.x = x;
          return { trap: String(e), x };
        }
      },
    };
  }
  return {
    stats,
    x: cur.x,
    async run(req) {
      const it = cur;
      const x = it.x;
      try {
        const blk = await it.handle(...enc0(x, req));
        stats.served++;
        seen(x);
        return { body: readRes(x, blk), x };
      } catch (e) {
        // A trap in the task: the host gives the stack back and frees the spans
        // of the task. -1: the trap was not clean or the heap could not be walked.
        // New requests then go to a new instance. Tasks that wait on the old one finish there.
        const freed = x.task_abort();
        if (freed === -1) {
          stats.walkFailed++;
          if (cur === it) {
            cur = instanceB(module, io);
            this.x = cur.x;
            stats.retired++;
          }
        } else stats.freed += freed;
        stats.traps++;
        seen(x);
        return { trap: String(e), x };
      }
    },
  };
}

// The request string in a js_alloc block: [ptr, len] for `handle`.
function enc0(x, req) {
  const bytes = enc.encode(req);
  const p = x.js_alloc(bytes.length);
  new Uint8Array(x.memory.buffer).set(bytes, p);
  return [p, bytes.length];
}

// The body the app must give for request `id` at recursion `depth`.
export function expected(id, depth = 50) {
  let sum = 0;
  for (let n = 1; n <= depth; n++) sum += n * 1000 + `level-${n}-of-request-${id}`.length + 1;
  return { sum, prefix: `id=${id} `, suffix: ` sum=${sum} fetch=f:${id} db=d:${id}` };
}

export function check(id, body, depth = 50) {
  const e = expected(id, depth);
  return body.startsWith(e.prefix) && body.endsWith(e.suffix);
}
