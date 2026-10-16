// The events of API.md 10.1 as JS values, and the outcome of the app back to Workers. The host decodes the event into
// a `Js` value, and `platform/Entry.roc` reads the same shapes (its table). PLAN.md 8b: `fetch`, `scheduled` and the
// `other` kinds. The other entry points (objects, RPC, the manifest) come in 8f.

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

// The outcome `Respond` as a Workers `Response`. The body: bytes, text, null, or a stream (a ref).
export function responseOf(o) {
  const headers = new Headers();
  for (const [k, v] of o.headers) headers.append(k, v);
  const init = { status: o.status, headers };
  if (o.webSocket) init.webSocket = o.webSocket;
  return new Response(o.body ?? null, init);
}
