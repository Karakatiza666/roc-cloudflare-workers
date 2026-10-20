// The platform helpers: the root `pf` of a program (API.md 6.4). Each one is a loop or a branch that a program
// cannot have (OP4). One `pf` object for each task: `spawn`, `writer`, `respond` and `passThrough` use its task.
import { Packed, Limited, TooLarge, isDec, decNumber, plain } from './values.js';
import { runAwait, errorOf, onLoss } from './program.js';
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
// At most `max` bytes of `v`: the rest waits in `st.rest` for the next read.
function join(a, b) {
  const out = new Uint8Array(a.byteLength + b.byteLength);
  out.set(a);
  out.set(b, a.byteLength);
  return out;
}
function cut(st, v, max) {
  if (v.byteLength <= max) return v;
  st.rest = v.subarray(max);
  return v.subarray(0, max);
}
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
// `pf.r2put` (MODULES.md 5.3): a put of a stream that may have no known length. R2 takes a stream only with a known
// length ("Provided readable stream must have a known length", a TypeError before any read), so on that error the
// stream goes as bytes: up to `R2_PART_BYTES` it is one put of the bytes, with each option. Past it, it is a multipart
// upload of parts of `R2_PART_BYTES` (the last one smaller), one part in memory at a time; an error aborts the upload.
export const R2_PART_BYTES = 5 * 1024 * 1024;
const R2_SUM_KEYS = ['md5', 'sha1', 'sha256', 'sha384', 'sha512'];
async function r2put(bucket, key, stream, options, signal) {
  options = options ?? undefined;
  try {
    return await bucket.put(key, stream, options);
  } catch (e) {
    if (!(e instanceof TypeError) || !/known length/.test(String(e.message)) || stream.locked) throw e;
  }
  const reader = stream.getReader();
  const part = new Uint8Array(R2_PART_BYTES);
  let n = 0, rest = null, done = false;
  // Fill `part` to `R2_PART_BYTES`, or to the end of the stream. A chunk past the part waits in `rest`.
  const fill = async () => {
    while (n < R2_PART_BYTES) {
      let v = rest;
      rest = null;
      if (!v) {
        const r = await reader.read();
        if (r.done) return void (done = true);
        v = bytesOf(r.value);
      }
      const take = Math.min(v.byteLength, R2_PART_BYTES - n);
      part.set(v.subarray(0, take), n);
      n += take;
      if (take < v.byteLength) rest = v.subarray(take);
    }
    // A full part: read on to the next bytes, so a stream of exactly one part is one put.
    while (!rest) {
      const r = await reader.read();
      if (r.done) return void (done = true);
      const v = bytesOf(r.value);
      if (v.byteLength) rest = v;
    }
  };
  try {
    await fill();
  } catch (e) {
    reader.cancel(e).catch(() => {});
    throw e;
  }
  if (done) return bucket.put(key, part.subarray(0, n), options);
  if (options?.onlyIf || R2_SUM_KEYS.some((k) => options?.[k] !== undefined)) {
    const e = new TypeError('R2 put: a stream with no known length over 5 MiB is a multipart upload, which takes no only_if and no checksum: give length_bytes');
    reader.cancel(e).catch(() => {});
    throw e;
  }
  const upload = await bucket.createMultipartUpload(key, { httpMetadata: options?.httpMetadata, customMetadata: options?.customMetadata });
  try {
    const parts = [];
    for (;;) {
      signal?.throwIfAborted();
      parts.push(await upload.uploadPart(parts.length + 1, part.subarray(0, n)));
      if (done) break;
      n = 0;
      await fill();
      if (n === 0) break;
    }
    const o = await upload.complete(parts);
    // The edge gives no `httpMetadata` and `customMetadata` in the result of `complete` (PLAN.md 11c, E28): the ones of the call.
    const meta = {};
    for (const k of R2_META) meta[k] = o[k];
    if (options?.httpMetadata) meta.httpMetadata = options.httpMetadata;
    if (options?.customMetadata) meta.customMetadata = options.customMetadata;
    meta.checksums = o.checksums;
    return meta;
  } catch (e) {
    reader.cancel(e).catch(() => {});
    await upload.abort().catch(() => {});
    throw e;
  }
}
// The writers of `pf.writer` by their readable side and by their writer (`close`, `respond`).
const writerOfStream = new WeakMap();
const writerOf = new WeakMap();

// WebSockets of `WebSocket.accept!` and `connect!` (MODULES.md 12.2): the state of each socket that `wsAccept` accepted.
// `queue`: the messages that came before a `receive` (text, or bytes as a `Uint8Array`). `waiters`: the `receive` calls
// that wait. `closed`: `{ code, reason, clean }` after the close. `onClose`: hooks (the end of a 101 response).
const sockets = new WeakMap();
// The server end of a `wsPair`, by its client end (the `webSocket` of a 101 response of `respond`).
const serverOf = new WeakMap();
function acceptSocket(ws) {
  const st = { queue: [], waiters: [], closed: null, onClose: [] };
  sockets.set(ws, st);
  ws.accept();
  // Bytes as an `ArrayBuffer`: with the compatibility flag of the standard `binaryType` the default is `blob`, which a
  // sync read cannot take.
  try {
    ws.binaryType = 'arraybuffer';
  } catch {}
  const close = (closed) => {
    if (st.closed) return;
    st.closed = closed;
    for (const w of st.waiters.splice(0)) w.give(closed);
    for (const f of st.onClose.splice(0)) f();
  };
  ws.addEventListener('message', (e) => {
    const v = typeof e.data === 'string' ? e.data : new Uint8Array(e.data);
    const w = st.waiters.shift();
    if (w) w.give(v);
    else st.queue.push(v);
  });
  ws.addEventListener('close', (e) => close({ code: e.code, reason: e.reason ?? '', clean: Boolean(e.wasClean) }));
  ws.addEventListener('error', (e) => close({ code: 1006, reason: String(e?.message ?? e?.error?.message ?? 'error'), clean: false }));
  return st;
}

// TCP sockets of `Tcp` (MODULES.md 12.3): the reader, the writer, a read that a lost race branch left (`pending`), the
// rest of a chunk that `max` cut, and the close.
const tcps = new WeakMap();
function tcpOf(s) {
  let st = tcps.get(s);
  if (st) return st;
  if (!s || typeof s.readable?.getReader !== 'function') throw new TypeError('tcp: not a socket of Tcp.connect! or Hyperdrive.connect!');
  st = { reader: null, writer: null, pending: null, rest: null, closed: false };
  s.closed?.then(() => (st.closed = true), () => (st.closed = true));
  tcps.set(s, st);
  return st;
}
// `p`, or a rejection when `signal` aborts first (a lost branch of `Io.race!`, OP8, or the end of the task).
function untilAbort(p, signal) {
  if (!signal) return p;
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise((resolve, reject) => {
    const on = () => reject(signal.reason);
    signal.addEventListener('abort', on, { once: true });
    p.then(
      (v) => (signal.removeEventListener('abort', on), resolve(v)),
      (e) => (signal.removeEventListener('abort', on), reject(e)),
    );
  });
}

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

// SQL parameters (MODULES.md 5.1, "Parameters"): the decoded CBOR array of the call, as the arguments of `bind` or `exec`.
// null, text, a Number and a Uint8Array go as they are. A BigInt is an integer of 2^53 or more: it goes as decimal text
// (D1 takes no BigInt, a Number rounds) when it fits I64, else it is a BadParam. A map is a tag or a record: BadParam.
const I64_MIN = -(1n << 63n), I64_MAX = (1n << 63n) - 1n;
class BadParam extends Error {
  constructor(message) { super(message); this.name = 'BadParam'; }
}
const kindOf = (v) => (Array.isArray(v) ? 'a list' : v instanceof Uint8Array ? 'bytes' : v === null ? 'null' : typeof v === 'object' ? 'a record or a tag' : typeof v);
export function sqlParams(params) {
  if (!Array.isArray(params)) {
    throw new BadParam(`SQL parameters must be a list or a tuple, not ${kindOf(params)}: write [x] for one parameter and (a, b) for more`);
  }
  return params.map((v, i) => {
    switch (typeof v) {
      case 'string': case 'number': return v;
      case 'bigint':
        if (v < I64_MIN || v > I64_MAX) throw new BadParam(`SQL parameter ${i}: the integer ${v} does not fit I64`);
        return v.toString();
      case 'undefined': throw new BadParam(`SQL parameter ${i}: undefined is not a SQL value`);
      case 'boolean': throw new BadParam(`SQL parameter ${i}: a Bool is not a SQL value, use 0 or 1`);
    }
    if (v === null || v instanceof Uint8Array) return v;
    // A tag 4 value (a Dec with a fraction) is a Number here: SQLite has no exact decimal.
    if (isDec(v)) return decNumber(v);
    throw new BadParam(`SQL parameter ${i}: ${kindOf(v)} is not a SQL value${v !== null && typeof v === 'object' && !Array.isArray(v) ? ', tag values are not SQL values, use Sql.null or Sql.or_null for NULL' : ''}`);
  });
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
    // `maxBytes`: the limit of all the packed fields together (MC11: the rows of a whole batch).
    packEach(array, key, maxBytes) {
      if (!Array.isArray(array)) throw new TypeError('packEach: the first argument must be an array');
      const budget = { left: maxBytes ?? Infinity };
      return array.map((item) => ({ ...item, [key]: new Packed(item?.[key], Infinity, budget) }));
    },
    // `v` as a JSON message: each tag 4 value (a Dec with a fraction) becomes a Number (`Queue.json`).
    plain(v) {
      return plain(v);
    },
    // `stmt.bind(...params)`: `params` is the decoded CBOR array of the call (`D1`, MODULES.md 5.1).
    bind(stmt, params) {
      return stmt.bind(...sqlParams(params));
    },
    // `sql.exec(text, ...params)` of a Durable Object (`Object.Self.sql!`): the same parameter rules as `bind`.
    sqlExec(sql, text, params) {
      return sql.exec(text, ...sqlParams(params));
    },
    // The value as a `Js` tree (J1 to J7), with a limit of its CBOR size: more is a TooLarge, before any copy into
    // wasm (MC11). `D1.rows!`: rows with no types do not go through `pack`.
    limit(value, maxBytes) {
      return new Limited(value, maxBytes ?? Infinity);
    },
    // The keys of an iterator of `[key, value]` entries (the sync KV `list()` of a Durable Object, `Object.Self.list!`),
    // as a `Js` tree with a limit of its CBOR size (MC11): the values stay in JS.
    keys(entries, maxBytes) {
      const out = [];
      for (const [k] of entries) out.push(k);
      return new Limited(out, maxBytes ?? Infinity);
    },
    // `Object.Self.set_alarm_in!`: `storage.setAlarm(Date.now() + delayMs)`, so the delay needs no clock crossing.
    alarmIn(storage, delayMs) {
      return storage.setAlarm(Date.now() + delayMs);
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
    // `R2.put!`, `put_with!` of a stream with no `length_bytes` (MODULES.md 5.3): the put, or the bytes or a multipart
    // upload for a stream with no known length. The signal of the program stops a multipart upload between parts.
    r2put(bucket, key, stream, options) {
      return r2put(bucket, key, stream, options, c?.signal);
    },
    // `Kv.get!`: the stream of `get(key, { type: "stream" })` to `max` bytes, or undefined for a key that is not there
    // (`null`). `readUpTo(null)` is no bytes, so a missing key needs its own helper.
    async readMaybe(stream, max) {
      if (stream === null || stream === undefined) return undefined;
      return this.readUpTo(stream, max);
    },
    // `Kv.get_with_metadata!`: the result of `getWithMetadata(key, { type: "stream" })` as `{ value, metadata }`: the bytes
    // to `max` (undefined: no key), and the metadata as `Packed` (undefined: none).
    async kvMeta(res, max) {
      const value = await this.readMaybe(res?.value, max);
      return { value, metadata: res?.metadata === null || res?.metadata === undefined ? undefined : new Packed(res.metadata) };
    },
    // `Kv.list!`: the result of `list()` as `{ keys: [{ name, expiration, metadata }], cursor }`, with the metadata as `Packed`.
    // A program has no loop (OP4). `cursor` is undefined for the last page.
    kvList(res) {
      const keys = res.keys.map((k) => ({ name: k.name, expiration: k.expiration, metadata: k.metadata === null || k.metadata === undefined ? undefined : new Packed(k.metadata) }));
      return { keys, cursor: res.list_complete ? undefined : res.cursor };
    },
    // `WebSocket.accept!` (MODULES.md 12.2): `new WebSocketPair()`, `accept()` of the server end with its message queue.
    // Gives `[client, server]`.
    wsPair() {
      const [client, server] = Object.values(new WebSocketPair());
      acceptSocket(server);
      serverOf.set(client, server);
      return [client, server];
    },
    // `WebSocket.connect!`: `accept()` of the `webSocket` of a response, with its message queue. No socket (the server did
    // not answer 101): undefined (`NotUpgrade`).
    wsAccept(ws) {
      if (ws === null || ws === undefined) return undefined;
      acceptSocket(ws);
      return ws;
    },
    // `WebSocket.receive!`: the next message (text, or bytes), or `{ code, reason, clean }` after the close. A wait on a
    // socket has no deadline (API.md 10.2). When `signal` aborts (a lost branch of `Io.race!`), the call stops and the
    // message stays for the next call (OP8). A message that a lost branch took goes back to the front of the queue
    // (`onLoss`), also when the branch took it in the same turn as the end of the race.
    wsReceive(ws, signal) {
      const st = sockets.get(ws);
      if (!st) throw new TypeError('wsReceive: not a socket of WebSocket.accept! or connect!');
      const taken = (m) => {
        onLoss(signal, () => st.queue.unshift(m));
        return m;
      };
      if (st.queue.length) return taken(st.queue.shift());
      if (st.closed) return st.closed;
      c.socketWait = true;
      return new Promise((resolve, reject) => {
        const w = {
          give(v) {
            signal?.removeEventListener('abort', onAbort);
            resolve(v === st.closed ? v : taken(v));
          },
        };
        const onAbort = () => {
          const i = st.waiters.indexOf(w);
          if (i >= 0) st.waiters.splice(i, 1);
          reject(signal.reason);
        };
        if (signal?.aborted) return reject(signal.reason);
        signal?.addEventListener('abort', onAbort, { once: true });
        st.waiters.push(w);
      });
    },
    // `Tcp.connect!` (MODULES.md 12.3): `connect({ hostname, port }, { secureTransport })` of `cloudflare:sockets` (a
    // dynamic import, so a Node test of the shim loads with no stand-in), then a wait for `opened`. Gives the socket.
    async tcpConnect(hostname, port, secureTransport) {
      const { connect } = await import('cloudflare:sockets');
      return this.tcpOpen(connect({ hostname, port }, { secureTransport, allowHalfOpen: false }));
    },
    // A wait for `opened` of a socket (`Hyperdrive.connect!`: the `connect()` of the binding). Gives the socket.
    async tcpOpen(socket) {
      await socket.opened;
      tcpOf(socket);
      return socket;
    },
    // `Tcp.read!`: the next bytes, at most `max` (the rest comes next), or undefined at the end. A wait on a socket has
    // no deadline (API.md 10.2). When `signal` aborts (a lost branch of `Io.race!`), the call stops, and the read that
    // it started stays for the next call (OP8). Bytes that a lost branch took go back to the front (`onLoss`), also
    // when the branch took them in the same turn as the end of the race: no byte is lost.
    async tcpRead(socket, max, signal) {
      const st = tcpOf(socket);
      const taken = (v) => {
        onLoss(signal, () => (st.rest = st.rest ? join(v, st.rest) : v));
        return v;
      };
      if (st.rest) {
        const v = st.rest;
        st.rest = null;
        return taken(cut(st, v, max));
      }
      st.reader ??= socket.readable.getReader();
      const read = (st.pending ??= st.reader.read());
      c.socketWait = true;
      let got;
      try {
        got = await untilAbort(read, signal);
      } catch (e) {
        // An abort keeps the read for the next call. A read that failed goes.
        if (!signal?.aborted && st.pending === read) st.pending = null;
        throw e;
      }
      if (st.pending === read) st.pending = null;
      return got.done ? undefined : taken(cut(st, bytesOf(got.value), max));
    },
    // `Tcp.write!`: `writer.write(bytes)`. A socket that is closed gives the text "closed" (`Closed` in Roc).
    async tcpWrite(socket, bytes) {
      const st = tcpOf(socket);
      if (st.closed) return 'closed';
      st.writer ??= socket.writable.getWriter();
      try {
        await st.writer.write(bytes);
      } catch (e) {
        if (st.closed) return 'closed';
        throw e;
      }
      return undefined;
    },
    // `Tcp.start_tls!` (MODULES.md 12.3): `socket.startTls()` needs a socket with no reader and no writer locked, so the
    // locks go first (a new reader and writer on the next call, of the new socket). It is an error, and the socket stays
    // plain and usable, when a read is in flight (`pending`, also one that a lost race left) or when received bytes are
    // unread (`rest`): bytes that came before the upgrade must never be read as if they came over TLS (STARTTLS injection).
    async tcpStartTls(socket) {
      const st = tcpOf(socket);
      if (st.pending) throw new Error('tcp: start_tls! while a read is in flight (a read that a lost race left): finish that read first');
      if (st.rest) throw new Error('tcp: unread bytes before start_tls!: read them first');
      st.reader?.releaseLock();
      st.writer?.releaseLock();
      st.reader = st.writer = null;
      return this.tcpOpen(socket.startTls());
    },
    // `Tcp.close!`: `socket.close()` with no wait; a rejection is dropped.
    tcpClose(socket) {
      const st = tcps.get(socket);
      if (st) st.closed = true;
      socket.close().catch(() => {});
      return undefined;
    },
    // `Email.send_raw!` and `reply!`: `new EmailMessage(from, to, raw)` of `cloudflare:email`. It is a dynamic import, so
    // a Node test of the shim loads with no stand-in for that module.
    async emailMessage(from, to, raw) {
      const { EmailMessage } = await import('cloudflare:email');
      return new EmailMessage(from, to, raw);
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
    // `Body.Writer.close!`: no wait. The body is complete now when it is the response of `Response.after` (API.md 10.2).
    close(writer) {
      const s = writerOf.get(writer);
      if (!s) throw new TypeError('close: not a writer of Body.writer!');
      s.finish(true);
      if (t && t.responseWriter === s && t.response === 'open') tasks.bodyComplete(t);
    },
    // `Response.after` (API.md 10.2, `Entry.finish!`): the outcome `Respond` (the shape of `platform/Entry.roc`) as a `Response` for
    // Workers now. The task goes on. Only in an event whose entry gave a `respond` hook (the `fetch` of a Worker, of a
    // named entry point and of a Durable Object), once: else an InvalidStateError (a crash of `Entry.finish!`).
    respond(o) {
      const h = t?.hooks;
      if (!h?.respond) throw new DOMException(`respond: not in a Fetch (${t?.kind ?? 'no task'})`, 'InvalidStateError');
      if (h.response) throw new DOMException('respond: the task responded already', 'InvalidStateError');
      const res = responseOf(o);
      h.response = res;
      // A stream of an open writer: the body is complete at its `close` (3b). Else it is complete now.
      const s = o.body instanceof ReadableStream ? writerOfStream.get(o.body) : undefined;
      t.responseWriter = s;
      // A 101 response of `WebSocket.accept!` is complete when its socket closes (API.md 10.2): the task stays.
      const ws = o.webSocket ? sockets.get(serverOf.get(o.webSocket)) : undefined;
      tasks.respond(t, Boolean((s && !s.closed) || (ws && !ws.closed)));
      if (ws && !ws.closed) ws.onClose.push(() => {
        if (t.response === 'open') tasks.bodyComplete(t);
      });
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
