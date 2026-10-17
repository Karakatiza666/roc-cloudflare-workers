// The events of API.md 10.1 as JS values, and the outcome of the app back to Workers. The host decodes the event into
// a `Js` value, and `platform/Entry.roc` reads the same shapes (its table). PLAN.md 8b: `fetch`, `scheduled` and the
// `other` kinds. 8f part 2: `queue`, `email` and `tail`. 8f part 1: RPC, `entrypointFetch`, the events of an object and the
// manifest.
import { Packed, pack } from './values.js';

// The fields of `Request.Cf` (MODULES.md 4): Roc name, Workers name, test of a good value.
const isText = (v) => typeof v === 'string';
const isU32 = (v) => Number.isInteger(v) && v >= 0 && v < 2 ** 32;
const isU64 = (v) => Number.isSafeInteger(v) && v >= 0;
const CF = [
  ['asn', 'asn', isU32], ['as_organization', 'asOrganization', isText], ['colo', 'colo', isText],
  ['country', 'country', isText], ['city', 'city', isText], ['continent', 'continent', isText],
  ['region', 'region', isText], ['region_code', 'regionCode', isText], ['postal_code', 'postalCode', isText],
  ['metro_code', 'metroCode', isText], ['latitude', 'latitude', isText], ['longitude', 'longitude', isText],
  ['timezone', 'timezone', isText], ['http_protocol', 'httpProtocol', isText], ['tls_version', 'tlsVersion', isText],
  ['tls_cipher', 'tlsCipher', isText], ['client_tcp_rtt_ms', 'clientTcpRtt', isU64],
];
const MISSING = Object.freeze({ Err: 'Missing' });

// `request.cf` in the tag form that Roc reads: `{ Ok: v }` or `{ Err: "Missing" }`, never null (MODULES.md 4).
// A value of another type is `Missing` too. `is_eu_country` is true only for "1". No cf: undefined (no field in Roc).
export function cfOf(cf) {
  if (cf === null || typeof cf !== 'object') return undefined;
  const out = {};
  for (const [name, js, ok] of CF) out[name] = ok(cf[js]) ? { Ok: cf[js] } : MISSING;
  out.is_eu_country = cf.isEUCountry === '1';
  return out;
}

// The body of a request: its `ReadableStream`, which crosses as a ref of the task (`Stream(Ref)`, API.md RS3), with no
// copy into wasm. `Body` reads it when Roc asks (PLAN.md 10b). No body: undefined (`Empty`).
export function bodyIn(request) {
  return request.body ?? undefined;
}

// The event `Fetch` (API.md 10.1).
export async function fetchEvent(request) {
  return {
    kind: 'fetch',
    request: { method: request.method, url: request.url, headers: [...request.headers], body: bodyIn(request), cf: cfOf(request.cf) },
  };
}

// The event `Scheduled`: `controller.cron` and `controller.scheduledTime`, the planned time of the run (MODULES.md 3).
export function scheduledEvent(controller) {
  return { kind: 'scheduled', cron: String(controller.cron), time_ms: Math.trunc(Number(controller.scheduledTime)) };
}

// The event `Other` for a handler name of the option `other` (API.md 10.1). The payload is the first argument (J1 to J7).
export function otherEvent(name, payload) {
  return { kind: 'other', name, payload };
}

// The event `Queue` (MODULES.md 6): the name of the queue and its messages. The body of a message crosses as `Packed`
// (CBOR, MC5), with no limit: a batch has the limit of the Queues config (MC11). A body that CBOR cannot write (a class
// instance, a number outside i64 and u64) is `undefined`, so one bad message does not fail the batch: Roc retries it.
export function queueEvent(batch) {
  const messages = Array.from(batch.messages ?? [], (m) => ({
    id: String(m.id),
    timestamp_ms: m.timestamp instanceof Date ? m.timestamp.getTime() : Math.trunc(Number(m.timestamp)),
    attempts: Number(m.attempts),
    body: packable(m.body) ? new Packed(m.body) : undefined,
  }));
  return { kind: 'queue', queue: String(batch.queue), messages };
}
function packable(body) {
  try {
    pack(body);
    return true;
  } catch {
    return false;
  }
}

// The event `Email` (MODULES.md 13): the fields of `ForwardableEmailMessage`. `raw` is a stream (a ref of the task).
// `canBeForwarded` is not in the Workers API: it is true unless the runtime says false.
export function emailEvent(message) {
  return {
    kind: 'email',
    from: String(message.from),
    to: String(message.to),
    headers: message.headers ? [...message.headers] : [],
    raw: message.raw ?? undefined,
    raw_size_bytes: Math.trunc(Number(message.rawSize ?? 0)),
    can_be_forwarded: message.canBeForwarded !== false,
  };
}

// The event `Tail` (MODULES.md 3): the items of `Worker.TraceItem` as one `Packed` value. The derived parser of `roc-cbor`
// 0.1.0 reads a `Try(a, [Missing])` field as the value, or as `Err(Missing)` when the key is absent: so a missing value is
// a missing key here (never `null`, never the tag form: `research/f2-queue/try_shape.roc`). `maxBytes`: the limit of the
// batch (MC11). Past it, the log lines are dropped from the end, over all items, and `warn` gets one text with the count.
export const TAIL_MAX = 1 << 20;
const present = (v) => v !== null && v !== undefined;
// `obj` with the keys of `fields` whose value is present.
const keep = (fields) => Object.fromEntries(Object.entries(fields).filter(([, v]) => present(v)));
const u64 = (v) => (Number.isSafeInteger(v) && v >= 0 ? v : undefined);
const headersOf = (h) => (h instanceof Headers ? [...h] : Object.entries(h ?? {})).map(([name, value]) => ({ name: String(name), value: String(value) }));
// `request.cf` as `Request.Cf` for the parser of CBOR: the same fields as `cfOf`, with no key for a missing one.
function cfPlain(cf) {
  const tagged = cfOf(cf);
  if (!tagged) return undefined;
  return Object.fromEntries(Object.entries(tagged).flatMap(([k, v]) => (v === MISSING ? [] : [[k, v.Ok ?? v]])));
}
// The console arguments as `JSON.stringify` writes them. A value that it cannot write (a BigInt, a cycle) is its `String(value)`.
function jsonText(m) {
  const one = (v) => {
    try {
      return JSON.stringify(v) === undefined ? String(v) : v;
    } catch {
      return String(v);
    }
  };
  try {
    return JSON.stringify(m) ?? String(m);
  } catch {
    return JSON.stringify(Array.isArray(m) ? m.map(one) : String(m));
  }
}
function traceItem(e) {
  const info = e.event;
  const fetched = info && typeof info === 'object' && info.request && typeof info.request === 'object';
  const r = fetched ? info.request : null;
  return keep({
    script_name: present(e.scriptName) ? String(e.scriptName) : undefined,
    outcome: String(e.outcome),
    event_timestamp_ms: u64(e.eventTimestamp),
    event: fetched
      ? keep({ request: keep({ method: String(r.method), url: String(r.url), headers: headersOf(r.headers), cf: cfPlain(r.cf) }), response: info.response && Number.isInteger(info.response.status) ? { status: info.response.status } : undefined })
      : undefined,
    logs: Array.from(e.logs ?? [], (l) => ({ timestamp_ms: Math.trunc(Number(l.timestamp)), level: String(l.level), message: jsonText(l.message) })),
    exceptions: Array.from(e.exceptions ?? [], (x) => ({ timestamp_ms: Math.trunc(Number(x.timestamp)), name: String(x.name), message: String(x.message) })),
  });
}
export function tailEvent(events, maxBytes = TAIL_MAX, warn = () => {}) {
  const items = Array.from(events, traceItem);
  const logs = items.map((i) => i.logs);
  for (const i of items) i.logs = [];
  let left = maxBytes - pack(items).byteLength;
  let dropped = 0, full = false;
  items.forEach((item, n) => {
    for (const l of logs[n]) {
      const size = pack(l).byteLength;
      if (!full && size <= left) {
        item.logs.push(l);
        left -= size;
      } else {
        full = true;
        dropped++;
      }
    }
  });
  if (dropped) warn(`tail: dropped ${dropped} log lines: the batch is larger than ${maxBytes} bytes`);
  return { kind: 'tail', items: new Packed(items) };
}

// The request of `fetch` as the value of the events `entrypointFetch` and the `fetch` of an object (as in `fetchEvent`).
const requestOf = (request) => ({ method: request.method, url: request.url, headers: [...request.headers], body: bodyIn(request), cf: cfOf(request.cf) });

// The event `Rpc` (API.md 10.1): a method of the default export (`entrypoint` "default") or of a named entry point. The
// argument is the JS value of the caller as one `Packed` value (API.md 5.2): Roc parses it into the type of the method.
// A call with no argument (`stub.method()`) sends `{}`, so a method whose argument type is `{}` takes it (PLAN.md 8f, FO6).
const argOf = (arg) => new Packed(arg === undefined ? {} : arg);
export function rpcEvent(entrypoint, method, arg) {
  return { kind: 'rpc', entrypoint, method, arg: argOf(arg) };
}

// The event `EntrypointFetch`: the `fetch` of a named entry point (a service binding with `entrypoint`, MODULES.md 8).
export function entrypointFetchEvent(entrypoint, request) {
  return { kind: 'entrypointFetch', entrypoint, request: requestOf(request) };
}

// The event `Object` of a Durable Object (API.md 10.1): its class, its id (`ctx.id.toString()`), and the event of the
// object: `init` (the constructor), `fetch`, `alarm` (`alarmInfo` of Workers, 0 and false when it gives none), `rpc`, and
// the socket events of the hibernation API (MODULES.md 12.1): the socket is a ref of the task, the message text or bytes
// (an `ArrayBuffer`, J2), the error an `Error` (J6).
export function objectEvent(cls, id, event) {
  return { kind: 'object', class: cls, id, event };
}
export const objectInit = () => ({ kind: 'init' });
export const objectFetch = (request) => ({ kind: 'fetch', request: requestOf(request) });
export const objectAlarm = (info) => ({ kind: 'alarm', retry_count: Number(info?.retryCount ?? 0), is_retry: Boolean(info?.isRetry ?? false) });
export const objectRpc = (method, arg) => ({ kind: 'rpc', method, arg: argOf(arg) });
export const objectSocketMessage = (ws, message) => ({ kind: 'socketMessage', socket: ws, message });
export const objectSocketClose = (ws, code, reason, wasClean) => ({ kind: 'socketClose', socket: ws, code: Number(code), reason: String(reason ?? ''), clean: Boolean(wasClean) });
export const objectSocketError = (ws, error) => ({ kind: 'socketError', socket: ws, error: error instanceof Error ? error : new Error(String(error)) });

// The event `Manifest` (API.md 10.1, AQ10): once, at load.
export function manifestEvent() {
  return { kind: 'manifest' };
}

// The outcome `Respond` as a Workers `Response`. The body: bytes, text, null, or a stream (a ref).
export function responseOf(o) {
  const headers = new Headers();
  for (const [k, v] of o.headers) headers.append(k, v);
  const init = { status: o.status, headers };
  if (o.webSocket) init.webSocket = o.webSocket;
  return new Response(o.body ?? null, init);
}
