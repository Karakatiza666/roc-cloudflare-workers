// The platform helpers: the root `pf` of a program (API.md 6.4). Each one is a loop or a branch that a program
// cannot have (OP4). One `pf` object for each task: `spawn`, `writer`, `respond` and `passThrough` use its task.
import { Packed, TooLarge } from './values.js';
import { runAwait, errorOf } from './program.js';
import { responseOf } from './events.js';

// The read state of each stream that `readUpTo`, `chunk` or `sha256` read (a stream is a ref of one task, RS1): its
// reader, the rest of a chunk that `chunk` cut, the end, and `consumed` (read to its end by `readUpTo`).
const readers = new WeakMap();
function readerOf(stream, what) {
  let r = readers.get(stream);
  if (r) return r;
  if (typeof stream?.getReader !== 'function') throw new TypeError(`${what}: the first argument must be a ReadableStream`);
  r = { reader: stream.getReader(), rest: null, done: false, consumed: false };
  readers.set(stream, r);
  return r;
}
const bytesOf = (v) => (v instanceof Uint8Array ? v : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : new Uint8Array(v));
function concat(chunks, n) {
  if (chunks.length === 1) return chunks[0];
  const out = new Uint8Array(n);
  let at = 0;
  for (const ch of chunks) {
    out.set(ch, at);
    at += ch.byteLength;
  }
  return out;
}
// One object of an R2 list as the record that `R2.roc` reads: `{ meta, checksums }` (the same two parts as the program of `R2.get!`).
const R2_META = ['key', 'version', 'size', 'etag', 'httpEtag', 'uploaded', 'httpMetadata', 'customMetadata'];
const R2_SUMS = ['md5', 'sha1', 'sha256', 'sha384', 'sha512'];
function r2pair(o) {
  const meta = {}, checksums = {};
  for (const k of R2_META) meta[k] = o[k];
  for (const k of R2_SUMS) checksums[k] = o.checksums?.[k];
  return { meta, checksums };
}
// The writers of `pf.writer` by their readable side and by their writer (`close`, `respond`).
const writerOfStream = new WeakMap();
const writerOf = new WeakMap();

// The pin table of an isolate (API.md RS2): values for later tasks, by name. `limit`: the shim option `pinLimit`.
// `now`: a clock. Each pin and unpin is counted (M11).
export function makePins(limit = 1000, now = () => Date.now()) {
  const table = new Map();
  const stats = { pins: 0, unpins: 0, expired: 0 };
  return {
    stats,
    get size() { return table.size; },
    pin(name, value, maxAgeMs) {
      if (typeof name !== 'string') throw new TypeError('pin: the name must be text');
      if (!table.has(name) && table.size >= limit) throw new RangeError(`pin: the pin table is full (${limit} entries, shim option pinLimit)`);
      table.set(name, { value, until: typeof maxAgeMs === 'number' ? now() + maxAgeMs : Infinity });
      stats.pins++;
    },
    pinned(name) {
      const e = table.get(name);
      if (!e) return undefined;
      if (now() >= e.until) {
        table.delete(name);
        stats.expired++;
        return undefined;
      }
      return e.value;
    },
    unpin(name) {
      if (table.delete(name)) stats.unpins++;
    },
  };
}

// t: the task (or undefined), c: its program context, shim: { pins, log }, tasks: the task table.
export function makeHelpers(t, c, shim, tasks) {
  return {
    // One value as `Packed` (API.md 5.2): JS writes tag 24 and the CBOR of the value into the result block.
    // `maxBytes`: the limit of its CBOR (a TooLarge above it). No limit when it is not given: the modules give it (8c).
    pack(value, maxBytes) {
      return new Packed(value, maxBytes ?? Infinity);
    },
    // The array with the field `key` of each item as a `Packed` value. The other fields stay (D1 `batch`).
    packEach(array, key, maxBytes) {
      if (!Array.isArray(array)) throw new TypeError('packEach: the first argument must be an array');
      return array.map((item) => ({ ...item, [key]: new Packed(item?.[key], maxBytes ?? Infinity) }));
    },
    // The item whose `id` is `id`, else undefined (OP7). `Queue.Message.ack!` finds its message with it.
    findById(array, id) {
      if (!Array.isArray(array)) throw new TypeError('findById: the first argument must be an array');
      return array.find((item) => item?.id === id);
    },
    // Runs the ops as an async program of the task (`Io.start!`). A throw goes to the log. The context of the
    // task (its refs and roots) stays until the program settles (RS1). Gives the promise (it never rejects).
    spawn(ops) {
      if (t) tasks.spawnStart(t);
      return runAwait(ops, c).then(
        () => undefined,
        (e) => {
          const err = errorOf(e);
          shim.log?.(`started program failed: task ${t?.id ?? '-'}: ${err.name}: ${String(err.message).slice(0, 200)}`);
        },
      ).finally(() => {
        if (t) tasks.spawnEnd(t);
      });
    },
    // `R2.list!`: the result of `bucket.list()` as `{ objects: [{ meta, checksums }], prefixes, truncated, cursor }`, all plain
    // data: a program has no loop (OP4), and a class instance for each object would be a ref each.
    r2list(res) {
      return { objects: res.objects.map(r2pair), prefixes: [...(res.delimitedPrefixes ?? [])], truncated: Boolean(res.truncated), cursor: res.cursor };
    },
    // The pin table (RS2): `Js.pin!`, `pinned!`, `unpin!` (8c).
    pin(name, value, maxAgeMs) {
      shim.pins.pin(name, value, maxAgeMs);
    },
    pinned(name) {
      return shim.pins.pinned(name);
    },
    unpin(name) {
      shim.pins.unpin(name);
    },
    // Reads a stream to `max` bytes, from where `chunk` stopped. Past `max`: a TooLarge (the module turns it into
    // `TooLarge`), and the stream is cancelled, before any copy into wasm (MC11). Gives the bytes. A stream that was
    // read to its end, or that another reader holds, is a TypeError (RS3: a stream can be read once). A null body (the
    // body of a 204 response of `fetch`, `Http.send!`) is no bytes.
    async readUpTo(stream, max) {
      if (stream === null) return new Uint8Array(0);
      const r = readerOf(stream, 'readUpTo');
      if (r.consumed) throw new TypeError('readUpTo: the body was read already');
      r.consumed = true;
      const chunks = [];
      let n = 0;
      const add = (value) => {
        n += value.byteLength;
        if (n > max) {
          r.reader.cancel().catch(() => {});
          throw new TooLarge(`readUpTo: the stream is larger than ${max} bytes`);
        }
        chunks.push(value);
      };
      if (r.rest) add(r.rest);
      r.rest = null;
      while (!r.done) {
        const { done, value } = await r.reader.read();
        if (done) r.done = true;
        else add(bytesOf(value));
      }
      return concat(chunks, n);
    },
    // The next chunk of a stream, at most `max` bytes (MC11: a larger chunk is cut, the rest comes next), or
    // undefined at the end (`Body.chunk!`).
    async chunk(stream, max) {
      const r = readerOf(stream, 'chunk');
      if (r.consumed) throw new TypeError('chunk: the body was read already');
      let value = r.rest;
      r.rest = null;
      while (!value && !r.done) {
        const got = await r.reader.read();
        if (got.done) r.done = true;
        else if (got.value.byteLength) value = bytesOf(got.value);
      }
      if (!value) return undefined;
      if (value.byteLength > max) {
        r.rest = value.subarray(max);
        value = value.subarray(0, max);
      }
      return value;
    },
    // The SHA-256 of a stream (`Body.sha256!`): `crypto.DigestStream` of Workers, so no byte goes to wasm. Where it is
    // missing (Node), or after `chunk`: the chunks in JS, then `crypto.subtle.digest`.
    async sha256(stream) {
      if (typeof crypto.DigestStream === 'function' && !readers.has(stream)) {
        const ds = new crypto.DigestStream('SHA-256');
        await stream.pipeTo(ds);
        return new Uint8Array(await ds.digest);
      }
      const all = await this.readUpTo(stream, Infinity);
      return new Uint8Array(await crypto.subtle.digest('SHA-256', all));
    },
    // `Body.compress!`, `decompress!`: the body (a stream, bytes, text or null) through a `CompressionStream` or a
    // `DecompressionStream` of `format` ("gzip", "deflate"). Gives the readable side. A stream of `writer` stays a
    // stream of that writer, so its response is complete at `close!` (API.md 10.2).
    transform(body, kind, format) {
      const T = kind === 'compress' ? CompressionStream : kind === 'decompress' ? DecompressionStream : null;
      if (!T) throw new TypeError(`transform: unknown kind ${kind}`);
      const t = new T(format);
      const input = body instanceof ReadableStream ? body : new Response(body ?? new Uint8Array(0)).body;
      const out = input.pipeThrough(t);
      const w = writerOfStream.get(input);
      if (w) writerOfStream.set(out, w);
      return out;
    },
    // A `TransformStream` for `Body.writer!` (MODULES.md 4): `{ readable, writer }`, the writer of its writable side.
    // The task stays while it is open, and its response is complete at `close` (API.md 10.2). When the reader cancels
    // the stream (the client stopped reading), the task is cancelled (`cancel(t, 'stream')`, PLAN.md 3b). At the end
    // of the task, an open writer is closed (the task returned) or aborted (a trap or a cancel): `tasks.end`.
    writer() {
      const ts = new TransformStream();
      const writer = ts.writable.getWriter();
      const s = { readable: ts.readable, writer, closed: false };
      s.finish = (ok) => {
        if (s.closed) return;
        s.closed = true;
        (ok ? writer.close() : writer.abort(new DOMException('the task ended', 'AbortError'))).catch(() => {});
      };
      writer.closed.catch(() => {
        if (!s.closed && t && !t.ended) tasks.cancel(t, 'stream');
        s.closed = true;
      });
      writerOfStream.set(ts.readable, s);
      writerOf.set(writer, s);
      if (t) (t.writers ??= new Set()).add(s);
      return { readable: ts.readable, writer };
    },
    // `Body.Writer.close!`: no wait. The body is complete now when it is the response of `respond!` (API.md 10.2).
    close(writer) {
      const s = writerOf.get(writer);
      if (!s) throw new TypeError('close: not a writer of Body.writer!');
      s.finish(true);
      if (t && t.responseWriter === s && t.response === 'open') tasks.bodyComplete(t);
    },
    // `Ctx.respond!` (API.md 10.2): the outcome `Respond` (the shape of `platform/Entry.roc`) as a `Response` for
    // Workers now. The task goes on. Only in an event whose entry gave a `respond` hook (the `fetch` of a Worker),
    // once: else an InvalidStateError (status 1, `InvalidState`).
    respond(o) {
      const h = t?.hooks;
      if (!h?.respond) throw new DOMException(`respond: not in the Fetch of a Worker (${t?.kind ?? 'no task'})`, 'InvalidStateError');
      if (h.response) throw new DOMException('respond: the task responded already', 'InvalidStateError');
      const res = responseOf(o);
      h.response = res;
      // A stream of an open writer: the body is complete at its `close` (3b). Else it is complete now.
      const s = o.body instanceof ReadableStream ? writerOfStream.get(o.body) : undefined;
      t.responseWriter = s;
      tasks.respond(t, Boolean(s && !s.closed));
      h.respond(res);
    },
    // `Ctx.pass_through!`: `ctx.passThroughOnException()`. Only in the `fetch` of a Worker, else InvalidStateError.
    passThrough() {
      const h = t?.hooks;
      if (h?.kind !== 'Fetch' || typeof h.ctx?.passThroughOnException !== 'function') throw new DOMException(`passThrough: not in the Fetch of a Worker (${t?.kind ?? 'no task'})`, 'InvalidStateError');
      h.ctx.passThroughOnException();
      h.passThrough = true;
    },
  };
}
