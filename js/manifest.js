// The manifest of the app (API.md AQ10, MODULES.md 3): the event `Manifest` gives it, `makeHandler` and the command
// `roc-cloudflare-workers sync` check it here.
import { BINDING_KINDS } from './bindings.js';

// Names that an RPC method cannot take: the handlers of the classes (`fetch`, `alarm`, ...) and `constructor`.
export const RESERVED = new Set(['fetch', 'scheduled', 'queue', 'email', 'tail', 'alarm', 'constructor', 'webSocketMessage', 'webSocketClose', 'webSocketError', 'then']);

// The manifest must be `{ default: { handlers, methods, ifaces }, objects: { Name: { handlers, methods, ifaces } },
// entrypoints: { ... } }`, with JS names, no method twice in a class and no reserved name (a platform bug or an app with
// such a method name: a throw). `ifaces`: the distinct interface names (`Rpc.iface("Ledger")`) of the methods that the
// class serves. It has one name at most (two are a throw with both names, MODULES.md 3). The result has the default
// methods as `default`, the handlers of the default export as `handlers`, and the interface name of each class as
// `iface` ("" for none; `defaultIface` for the default export).
export function checkManifest(m) {
  const isName = (n) => typeof n === 'string' && /^[A-Za-z_$][\w$]*$/.test(n);
  const names = (list, what) => {
    if (!Array.isArray(list) || !list.every(isName) || new Set(list).size !== list.length) throw new Error(`makeHandler: the manifest has bad ${what}: ${JSON.stringify(list)}`);
    for (const n of list) if (RESERVED.has(n)) throw new Error(`makeHandler: the RPC method ${n} (${what}) has the name of a handler`);
    return list;
  };
  const ifaceOf = (c, what) => {
    const list = c.ifaces ?? [];
    if (!Array.isArray(list) || !list.every((n) => typeof n === 'string' && n !== '')) throw new Error(`makeHandler: the manifest has bad interface names for ${what}: ${JSON.stringify(list)}`);
    if (list.length > 1) throw new Error(`makeHandler: ${what} serves methods of two interfaces: ${list.map((n) => JSON.stringify(n)).join(' and ')}. Its methods must come from one Rpc.iface value (or from values with the same name)`);
    return list[0] ?? '';
  };
  const d = m.default ?? {};
  const out = { default: names(d.methods ?? [], 'default methods'), handlers: d.handlers ?? [], defaultIface: ifaceOf(d, 'the default export'), objects: {}, entrypoints: {}, bindings: [], crons: [] };
  for (const kind of ['objects', 'entrypoints']) {
    for (const [name, c] of Object.entries(m[kind] ?? {})) {
      if (!isName(name)) throw new Error(`makeHandler: the class name ${JSON.stringify(name)} is not a JS name`);
      if (name === 'default') throw new Error('makeHandler: a class cannot have the name default');
      out[kind][name] = { handlers: c.handlers ?? [], methods: names(c.methods ?? [], `methods of ${name}`), iface: ifaceOf(c, `the ${kind === 'objects' ? 'class' : 'entry point'} ${name}`) };
    }
  }
  // MODULES.md 3: a binding name once, a known kind, and an object namespace of this Worker (no `script`) names a class
  // of `objects`, with the same interface name as the class when both have one (`b.iface`, `Rpc.iface`): the types check it
  // in the compiler only when the class value is imported (the other Workers: `roc-cloudflare-workers sync`).
  for (const b of m.bindings ?? []) {
    if (typeof b?.name !== 'string' || b.name === '') throw new Error(`makeHandler: a binding of the manifest has no name: ${JSON.stringify(b)}`);
    if (!Object.hasOwn(BINDING_KINDS, b.kind)) throw new Error(`makeHandler: the binding ${b.name} has the unknown kind ${JSON.stringify(b.kind)}`);
    if (out.bindings.some((x) => x.name === b.name)) throw new Error(`makeHandler: the binding ${b.name} is twice in Worker.new bindings`);
    if (b.kind === 'object' && !b.script && !Object.hasOwn(out.objects, b.class)) throw new Error(`makeHandler: the namespace ${b.name} has the class ${b.class}, and the app has no such class: add Object.class("${b.class}", ...) to the field objects of Worker, or give the script of the class (Object.namespace("${b.name}", { class: "${b.class}", script: "<worker>" }))`);
    if (b.kind === 'object' && !b.script && b.iface && out.objects[b.class].iface && b.iface !== out.objects[b.class].iface) throw new Error(`makeHandler: the namespace ${b.name} has the interface ${JSON.stringify(b.iface)}, and the class ${b.class} serves the interface ${JSON.stringify(out.objects[b.class].iface)}`);
    out.bindings.push(b);
  }
  for (const c of m.crons ?? []) {
    if (typeof c !== 'string' || out.crons.includes(c)) throw new Error(`makeHandler: the cron ${JSON.stringify(c)} is twice in Worker.new crons, or not text`);
    out.crons.push(c);
  }
  out.traps = m.traps == null ? null : checkTraps(m.traps);
  return out;
}

// The causes of `Worker.OnTrap` (TR2), with their manifest names. The Roc field of `crash` is `crashed` (a keyword).
export const TRAP_CAUSES = ['default', 'crash', 'alarm', 'cpu', 'oom', 'shed', 'deadline', 'cancelled', 'event', 'failed'];
// The limits of a fixed response (TR5, TR6, decided O6, O7).
export const TRAP_LIMITS = { headers: 16, valueBytes: 1024, bodyBytes: 4096 };
// TR6: header names that a fixed response cannot give. Workers sets the length from the body.
const REFUSED_HEADERS = new Set(['content-length', 'transfer-encoding', 'connection', 'upgrade', 'keep-alive', 'set-cookie']);
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

// The table of `on_trap` (TR5, TR6): `default` and the given causes, each `{ status, headers: [[name, value], ...], body:
// Uint8Array }`. A bad value is a throw that names the Roc field (`on_trap.crashed.status`), so the load fails. The result has the
// same form, with plain arrays and the body as a Uint8Array of its own (no other code has a reference to it).
export function checkTraps(t) {
  // The text names the Roc field: the cause `crash` is the field `crashed` (audit 0.0.10, N13).
  const bad = (field, why) => new Error(`makeHandler: Worker.new on_trap.${field.replace(/^crash(?=\.|\[|$)/, 'crashed')}: ${why}`);
  if (typeof t !== 'object' || Array.isArray(t)) throw bad('', `the table is not an object: ${JSON.stringify(t)}`);
  if (!Object.hasOwn(t, 'default')) throw bad('default', 'the field default is missing');
  const out = {};
  for (const [cause, f] of Object.entries(t)) {
    if (!TRAP_CAUSES.includes(cause)) throw bad(cause, `the cause is not one of ${TRAP_CAUSES.map((c) => (c === 'crash' ? 'crashed' : c)).join(', ')}`);
    if (typeof f !== 'object' || f === null) throw bad(cause, 'the entry is not an object');
    const status = typeof f.status === 'bigint' ? Number(f.status) : f.status;
    if (!Number.isInteger(status) || status < 400 || status > 599) throw bad(`${cause}.status`, `the status ${status} is not 400 to 599`);
    const headers = f.headers ?? [];
    if (!Array.isArray(headers)) throw bad(`${cause}.headers`, 'the headers are not a list');
    if (headers.length > TRAP_LIMITS.headers) throw bad(`${cause}.headers`, `${headers.length} headers, the limit is ${TRAP_LIMITS.headers}`);
    const pairs = headers.map((h, i) => {
      if (!Array.isArray(h) || h.length !== 2 || typeof h[0] !== 'string' || typeof h[1] !== 'string') throw bad(`${cause}.headers[${i}]`, `not a name and a value: ${JSON.stringify(h)}`);
      const [name, value] = h;
      if (!TOKEN.test(name)) throw bad(`${cause}.headers[${i}].name`, `${JSON.stringify(name)} is not an HTTP token`);
      if (REFUSED_HEADERS.has(name.toLowerCase())) throw bad(`${cause}.headers[${i}].name`, `the header ${name} cannot be in a fixed response (${[...REFUSED_HEADERS].join(', ')})`);
      if (/[\r\n\0]/.test(value)) throw bad(`${cause}.headers[${i}].value`, `the value of ${name} has a CR, an LF or a NUL`);
      const n = new TextEncoder().encode(value).length;
      if (n > TRAP_LIMITS.valueBytes) throw bad(`${cause}.headers[${i}].value`, `the value of ${name} has ${n} bytes, the limit is ${TRAP_LIMITS.valueBytes}`);
      return [name, value];
    });
    if (!(f.body instanceof Uint8Array)) throw bad(`${cause}.body`, 'the body is not bytes');
    if (f.body.length > TRAP_LIMITS.bodyBytes) throw bad(`${cause}.body`, `${f.body.length} bytes, the limit is ${TRAP_LIMITS.bodyBytes}`);
    out[cause] = { status, headers: pairs, body: f.body.slice() };
  }
  return out;
}

// TR2: the cause of a runner result (`js/runner.js`). A result with no trap is an outcome that is not `Respond` (`Failed`,
// `Unhandled`, another one): `failed`.
export function causeOf(r) {
  if (!r.trap) return 'failed';
  if (r.cancelled) return r.cancelled === 'deadline' ? 'deadline' : 'cancelled';
  if (r.shed) return 'shed';
  if (r.cause === 'oom' || r.cause === 'cpu' || r.cause === 'event') return r.cause;
  if (r.alarm) return 'alarm';
  return 'crash';
}

// The response of `fetch` for a trap or an outcome that is not `Respond` (TR1, TR4, TR7). `traps`: the checked table, or null.
// It uses only JS values: no export of the instance, no wasm memory, no app code. A table entry gives a new copy of its
// body each time (a body is read once). `retryAfter`: the value of `retry-after` on `shed` and `oom` when the entry has
// none. With no table: the response of 0.0.2 (`trap <text>`, or no body for an outcome), plus `retry-after` (O2).
export function trapResponse(traps, r, retryAfter) {
  const cause = causeOf(r);
  const retry = cause === 'shed' || cause === 'oom';
  if (!traps) {
    if (!r.trap) return new Response(null, { status: 500 });
    return new Response(`trap ${r.trap}`, retry ? { status: r.status ?? 500, headers: { 'retry-after': retryAfter } } : { status: r.status ?? 500 });
  }
  const f = traps[cause] ?? traps.default;
  const headers = new Headers(f.headers);
  if (retry && !headers.has('retry-after')) headers.set('retry-after', retryAfter);
  return new Response(f.body.slice(), { status: f.status, headers });
}
