// Interface names at run time (MODULES.md 3, 8): `Rpc.iface` names in the manifest, and the load errors of `checkManifest`. Node only.
// node bench/iface-test.mjs [dir with the wasm files [conformance]]    (default: bench/out; `conformance`: part 0 only)
//   app_link_callee.wasm  default Ledger, entry point Admin (AdminApi), class Room (RoomApi), class Plain (no Rpc method)
//   app_link_caller.wasm  service LEDGER (Ledger), service ADMIN (AdminApi), remote namespace ROOMS (class Room, RoomApi)
//   conformance.wasm      default Default, class Counter (Counter), entry point Admin, namespace COUNTERS (Counter)
//   app_iface_two.wasm    the class Mixed serves two interfaces (Alpha, Beta): the load fails
//   app_iface_ns.wasm     the namespace ROOMS has the interface Wrong, the class Room serves RoomApi: the load fails
// The same names cross Workers in bench/sync-cross-test.mjs.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { manifestOf } from '../js/runner.js';
import { manifestEvent } from '../js/events.js';
import { checkManifest } from '../js/manifest.js';
import { makeHandler, objectClass, entrypointClass } from './cf-node.mjs';

const dir = resolve(process.argv[2] ?? join(fileURLToPath(new URL('..', import.meta.url)), 'bench/out'));
let failed = false;
const fail = (...m) => {
  failed = true;
  console.log('FAIL', ...m);
};
const pass = (...m) => console.log('PASS', ...m);
const check = (name, cond, why) => (cond ? pass(name) : fail(`${name}: ${why}`));
const raw = (f) => manifestOf(new WebAssembly.Module(readFileSync(join(dir, f))), manifestEvent());
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const throws = (name, re, f) => {
  try {
    f();
  } catch (e) {
    return check(name, re.test(String(e.message)), `the message does not match ${re}: ${e.message}`);
  }
  fail(`${name}: no throw`);
};

// ---- 0. The conformance app (bench/out, or the build of a revert: `node bench/iface-test.mjs <dir> conformance` runs this part only) ----
{
  const k = raw('conformance.wasm');
  check('0a the conformance app: ifaces of the default export, a class and an entry point', same([k.default.ifaces, k.objects.Counter.ifaces, k.entrypoints.Admin.ifaces], [['Default'], ['Counter'], ['Admin']]), JSON.stringify([k.default.ifaces, k.objects.Counter.ifaces, k.entrypoints.Admin.ifaces]));
  check('0b a class with many methods of one interface has one name, not one for each method', same(k.objects.Counter.ifaces, ['Counter']) && k.objects.Counter.methods.length > 3, JSON.stringify(k.objects.Counter));
  check('0c a class with no Rpc method has ifaces []', same(k.objects.Flaky.ifaces, []), JSON.stringify(k.objects.Flaky));
  const n = k.bindings.find((x) => x.name === 'COUNTERS');
  check('0d namespace COUNTERS of a class of this Worker has the iface of the class', n?.iface === 'Counter' && n.iface === k.objects.Counter.ifaces[0], JSON.stringify(n));
  check('0e a binding of another kind has no iface', !('iface' in k.bindings.find((x) => x.name === 'KV')), JSON.stringify(k.bindings));
  check('0f checkManifest accepts the conformance manifest', checkManifest(k).defaultIface === 'Default', '');
}
if (process.argv[3] === 'conformance') {
  console.log(failed ? 'FAILED' : 'all passed');
  process.exit(failed ? 1 : 0);
}

// ---- 1. The manifest of a built app has `ifaces` on the default export, the classes and the entry points ----
{
  const m = raw('app_link_callee.wasm');
  check('1a default export: ifaces is ["Ledger"]', same(m.default.ifaces, ['Ledger']), JSON.stringify(m.default));
  check('1b class Room: ifaces is ["RoomApi"]', same(m.objects.Room.ifaces, ['RoomApi']), JSON.stringify(m.objects.Room));
  check('1c named entry point Admin: ifaces is ["AdminApi"]', same(m.entrypoints.Admin.ifaces, ['AdminApi']), JSON.stringify(m.entrypoints.Admin));
  check('1d a class with no Rpc method has ifaces []', same(m.objects.Plain.ifaces, []), JSON.stringify(m.objects.Plain));
  const c = checkManifest(m);
  check('1e checkManifest: defaultIface, class iface, entry point iface', c.defaultIface === 'Ledger' && c.objects.Room.iface === 'RoomApi' && c.entrypoints.Admin.iface === 'AdminApi' && c.objects.Plain.iface === '', JSON.stringify(c));
}

// ---- 2. A binding has `iface`: a service binding, a remote namespace, a namespace of a class of this Worker ----
{
  const m = raw('app_link_caller.wasm');
  const b = (n) => m.bindings.find((x) => x.name === n);
  check('2a service LEDGER has iface "Ledger"', b('LEDGER')?.iface === 'Ledger', JSON.stringify(b('LEDGER')));
  check('2b service ADMIN has iface "AdminApi"', b('ADMIN')?.iface === 'AdminApi', JSON.stringify(b('ADMIN')));
  check('2c remote namespace ROOMS has class Room, script callee and iface "RoomApi"', same(b('ROOMS'), { name: 'ROOMS', kind: 'object', class: 'Room', script: 'callee', iface: 'RoomApi' }), JSON.stringify(b('ROOMS')));
}

// ---- 3. checkManifest: one interface name for a class, an entry point and the default export ----
const empty = () => ({ default: { handlers: [], methods: [], ifaces: [] }, objects: {}, entrypoints: {}, bindings: [], crons: [] });
{
  const two = empty();
  two.objects.Room = { handlers: [], methods: ['a', 'b'], ifaces: ['RoomApi', 'Other'] };
  throws('3a a class that serves two interfaces: the error names the class and both names', /the class Room serves methods of two interfaces: "RoomApi" and "Other"/, () => checkManifest(two));
  const ep = empty();
  ep.entrypoints.Admin = { handlers: [], methods: ['a', 'b'], ifaces: ['AdminApi', 'Other'] };
  throws('3b an entry point that serves two interfaces: the error names it and both names', /the entry point Admin serves methods of two interfaces: "AdminApi" and "Other"/, () => checkManifest(ep));
  const def = empty();
  def.default.ifaces = ['Ledger', 'Other'];
  throws('3c the default export that serves two interfaces: the error names both', /the default export serves methods of two interfaces: "Ledger" and "Other"/, () => checkManifest(def));
  const bad = empty();
  bad.objects.Room = { handlers: [], methods: [], ifaces: [''] };
  throws('3d an empty interface name is a bad manifest', /bad interface names for the class Room/, () => checkManifest(bad));
  const old = empty();
  delete old.default.ifaces;
  check('3e a manifest with no ifaces (a Worker built before Rpc.iface) loads with no interface', checkManifest(old).defaultIface === '', JSON.stringify(checkManifest(old)));
}

// ---- 4. checkManifest: a namespace of a class of this Worker has the interface of the class ----
{
  const ns = (iface, script) => {
    const m = empty();
    m.objects.Room = { handlers: [], methods: ['a'], ifaces: ['RoomApi'] };
    m.bindings.push({ name: 'ROOMS', kind: 'object', class: 'Room', ...(script ? { script } : {}), ...(iface ? { iface } : {}) });
    return m;
  };
  throws('4a a namespace with another interface than its class: the error names the namespace, the class and both names', /the namespace ROOMS has the interface "Other", and the class Room serves the interface "RoomApi"/, () => checkManifest(ns('Other')));
  check('4b the same interface loads', checkManifest(ns('RoomApi')).bindings.length === 1, '');
  check('4c a namespace with no interface loads', checkManifest(ns('')).bindings.length === 1, '');
  const noClassIface = ns('Other');
  noClassIface.objects.Room.ifaces = [];
  check('4d a class with no Rpc method: any namespace interface loads', checkManifest(noClassIface).bindings.length === 1, '');
  // A class of another Worker (script) is not in objects: sync compares it, the load does not.
  const remote = empty();
  remote.bindings.push({ name: 'FAR', kind: 'object', class: 'Far', script: 'other', iface: 'Far' });
  check('4e a remote namespace loads', checkManifest(remote).bindings.length === 1, '');
  const withScript = ns('Other', 'other');
  check('4f a namespace with a script is not compared with the class of this Worker', checkManifest(withScript).bindings.length === 1, '');
}

// ---- 5. A built app with such a manifest does not load (no request needed) ----
{
  const load = (f) => makeHandler(new WebAssembly.Module(readFileSync(join(dir, f))), { log: () => {} });
  throws('5a app_iface_two: the class Mixed with two interfaces: the load fails and the error has both names', /the class Mixed serves methods of two interfaces: "Alpha" and "Beta"/, () => load('app_iface_two.wasm'));
  throws('5b app_iface_ns: the namespace and its class with two interfaces: the load fails and the error has both names', /the namespace ROOMS has the interface "Wrong", and the class Room serves the interface "RoomApi"/, () => load('app_iface_ns.wasm'));
  objectClass('Room');
  objectClass('Plain');
  entrypointClass('Admin');
  check('5c the callee app loads', load('app_link_callee.wasm') !== undefined, '');
}

console.log(failed ? 'FAILED' : 'all passed');
process.exit(failed ? 1 : 0);
