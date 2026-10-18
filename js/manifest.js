// The manifest of the app (API.md AQ10, MODULES.md 3): the event `Manifest` gives it, `makeHandler` and the command
// `roc-cloudflare-workers sync` check it here.
import { BINDING_KINDS } from './bindings.js';

// Names that an RPC method cannot take: the handlers of the classes (`fetch`, `alarm`, ...) and `constructor`.
export const RESERVED = new Set(['fetch', 'scheduled', 'queue', 'email', 'tail', 'alarm', 'constructor', 'webSocketMessage', 'webSocketClose', 'webSocketError', 'then']);

// The manifest must be `{ default: { handlers, methods }, objects: { Name: { handlers, methods } }, entrypoints: { ... } }`,
// with JS names, no method twice in a class and no reserved name (a platform bug or an app with such a method name: a
// throw). The result has the default methods as `default` and the handlers of the default export as `handlers`.
export function checkManifest(m) {
  const isName = (n) => typeof n === 'string' && /^[A-Za-z_$][\w$]*$/.test(n);
  const names = (list, what) => {
    if (!Array.isArray(list) || !list.every(isName) || new Set(list).size !== list.length) throw new Error(`makeHandler: the manifest has bad ${what}: ${JSON.stringify(list)}`);
    for (const n of list) if (RESERVED.has(n)) throw new Error(`makeHandler: the RPC method ${n} (${what}) has the name of a handler`);
    return list;
  };
  const d = m.default ?? {};
  const out = { default: names(d.methods ?? [], 'default methods'), handlers: d.handlers ?? [], objects: {}, entrypoints: {}, bindings: [], crons: [] };
  for (const kind of ['objects', 'entrypoints']) {
    for (const [name, c] of Object.entries(m[kind] ?? {})) {
      if (!isName(name)) throw new Error(`makeHandler: the class name ${JSON.stringify(name)} is not a JS name`);
      if (name === 'default') throw new Error('makeHandler: a class cannot have the name default');
      out[kind][name] = { handlers: c.handlers ?? [], methods: names(c.methods ?? [], `methods of ${name}`) };
    }
  }
  // MODULES.md 3: a binding name once, a known kind, and an object namespace of this Worker (no `script`) names a class
  // of `objects`.
  for (const b of m.bindings ?? []) {
    if (typeof b?.name !== 'string' || b.name === '') throw new Error(`makeHandler: a binding of the manifest has no name: ${JSON.stringify(b)}`);
    if (!Object.hasOwn(BINDING_KINDS, b.kind)) throw new Error(`makeHandler: the binding ${b.name} has the unknown kind ${JSON.stringify(b.kind)}`);
    if (out.bindings.some((x) => x.name === b.name)) throw new Error(`makeHandler: the binding ${b.name} is twice in Worker.new bindings`);
    if (b.kind === 'object' && !b.script && !Object.hasOwn(out.objects, b.class)) throw new Error(`makeHandler: the namespace ${b.name} has the class ${b.class}, and the app has no such class: add Object.class("${b.class}", ...) to the field objects of Worker, or give the script of the class (Object.namespace("${b.name}", { class: "${b.class}", script: "<worker>" }))`);
    out.bindings.push(b);
  }
  for (const c of m.crons ?? []) {
    if (typeof c !== 'string' || out.crons.includes(c)) throw new Error(`makeHandler: the cron ${JSON.stringify(c)} is twice in Worker.new crons, or not text`);
    out.crons.push(c);
  }
  return out;
}
