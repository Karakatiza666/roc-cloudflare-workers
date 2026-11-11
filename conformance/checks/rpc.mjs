// RPC (MODULES.md 8, PLAN.md 8f part 1): routes of conformance/RpcRoutes.roc through the service bindings `SELF` (the
// default export of this Worker) and `ADMIN` (its named entry point `Admin`).
import { answer } from '../assert.mjs';

const self = Symbol.for('miniflare.kCurrentWorker');
export const options = { serviceBindings: { SELF: self, ADMIN: { name: self, entrypoint: 'Admin' } } };

export const checks = [
  ['rpc a service binding RPC call to an rpc method of the default export gives the reply', async (t) => {
    answer(await t.get('/rpc/ping'), 'Ok("default ping 5")');
    answer(await t.get('/rpc/ping_io'), 'Ok("default ping 6")');
  }],
  ['rpc one Rpc constant calls an object method and a service method', async (t) => {
    answer(await t.get('/objects/rpc/ping?name=p'), 'Ok("object ping 7")');
    answer(await t.get('/rpc/ping'), 'Ok("default ping 5")');
  }],
  ['rpc an unknown method of a service throws (RpcErr)', async (t) =>
    answer(await t.get('/rpc/nothere'), 'Err(Infra(RpcErr({ message: "The RPC receiver does not implement the method \\"nothere\\".", name: "TypeError" })))')],
  ['rpc Service.fetch! on a binding with entrypoint Admin reaches the fetch! of Admin', async (t) => {
    answer(await t.get('/rpc/admin_fetch'), '200 admin fetch http://x/hello');
    answer(await t.get('/rpc/admin_fetch_io'), '200 admin fetch http://x/hello');
  }],
  ['rpc a method of the named entry point Admin', async (t) => answer(await t.get('/rpc/admin_call'), 'Ok("purged v1/")')],
  // roc-cbor 0.5.0: a List(U8) writes a byte string, so it is a Uint8Array too. Cbor.U8Array writes an array of integers.
  ['rpc typed bytes (MC5): a Cbor.Bytes and a List(U8) field reach a JS callee as a Uint8Array, a Cbor.U8Array as an Array', async (t) =>
    answer(await t.get('/rpc/inspect'), 'Ok({ arr: "Array", data: "Uint8Array", list: "Uint8Array" })')],
  // Cbor.js_values: an RPC reply from JS reads undefined and null of a field as no key.
  ['rpc a JS reply with a null and an undefined field reads them as absent (UndefinedAsNull, NullAsAbsent)', async (t) =>
    answer(await t.get('/rpc/jsnull'), 'Ok({ a: 1, extra: Err(Missing), note: Err(Missing) })')],
  // Cbor.js_values: an RPC argument from a JS caller reads undefined and null of a field as no key.
  ['rpc a JS caller gives a field as null, undefined, no key or text: the Roc callee reads the first three as absent', async (t) =>
    answer(await t.get('/__greet'), '[{"Ok":"ann"},{"Ok":"bob"},{"Ok":"cy"},{"Ok":"Dr dee"}]')],
  // roc-cbor 0.5.0: a U128 and an I128 above 64 bits cross as bignums: a BigInt in JS, both ways.
  ['rpc a U128 and an I128 above 64 bits reach a JS callee as BigInt and come back exact (bignums, tags 2 and 3)', async (t) =>
    answer(await t.get('/rpc/wide'), 'Ok({ i: -1267650600228229401496703205375, kinds: "bigint bigint", u: 1267650600228229401496703205377 })')],
  // FO6 (PLAN.md 8f): `stub.hello()` with no argument reaches a method whose argument type is `{}`. The reply is an
  // `Reply` of `Rpc.roc` (MODULES.md 8): `{ Ok: value }`.
  ['rpc a JS call with no argument of a method whose argument type is {} (FO6)', async (t) => {
    const r = await t.get('/__noarg');
    answer(r, '{"default":{"Ok":"default hello"},"object":{"Ok":"object hello"}}');
  }],
  ['rpc the RPC limit: a reply above 32 MiB is RpcErr, a small one passes', async (t) => {
    const r = await t.get('/rpc/big');
    if (!r.body.startsWith('Err Infra(RpcErr(')) throw new Error(`got ${r.status} ${r.body.slice(0, 300)}`);
    answer(await t.get('/rpc/small'), 'Ok 1000');
    return r.body.slice(0, 200);
  }],
];
