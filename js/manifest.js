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
  return out;
}
