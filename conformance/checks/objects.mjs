// Durable Objects (MODULES.md 7, 9, PLAN.md 8f part 1): routes of conformance/ObjectRoutes.roc on the local Durable
// Objects of Miniflare (SQLite-backed, and one KV-backed class). The object SQL constraint checks are the local part of
// PLAN.md 8d for `Object.Self`. Each check gives the text that the route answered.
import { answer, eq, ok } from '../assert.mjs';

const sqlite = (className) => ({ className, useSQLite: true });
export const durableObjects = {
  COUNTERS: sqlite('Counter'), STORES: sqlite('Store'), FLAKY: sqlite('Flaky'), SLOW: sqlite('Slow'), TICKERS: sqlite('Ticker'),
  KVONLY: { className: 'KvOnly', useSQLite: false },
};
export const options = { durableObjects, kvNamespaces: ['OBJFLAGS'] };

const counter = (t, op, name = 'sql', extra = '') => t.get(`/objects/counter/${op}?name=${name}${extra}`);
const has = (r, part) => ok(r.status === 200 && r.body.includes(part), `got ${r.status} ${JSON.stringify(r.body.slice(0, 400))}, want a text with ${JSON.stringify(part)}`);
const ticks = (t) => t.logs.filter((l) => String(l.message).includes('"msg":"ticker alarm"')).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{'))));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const constraint = (kind, message) => `Err(Constraint({ kind: ${kind}, message: ${JSON.stringify(message)} }))`;

// A second Miniflare that must not start: the error names `name`.
async function loadFails(t, entry, name) {
  const mf = t.start({ durableObjects: { COUNTERS: sqlite('Counter') } }, entry);
  try {
    await mf.ready;
  } catch (e) {
    const text = String(e.message);
    ok(text.includes(name), `the load failed, but the error does not name ${name}: ${text.slice(0, 300)}`);
    return text.split('\n').find((l) => l.includes(name)).trim().slice(0, 200);
  } finally {
    await mf.dispose().catch(() => {});
  }
  throw new Error('the worker loaded');
}

export const checks = [
  // The alarm of a Ticker runs 3 times (2 s, then 4 s of backoff): it starts now, and the last check of this file reads it.
  ['objects ticker: set_alarm! for the retry check', async (t) => answer(await t.get('/objects/ticker?name=tk'), 'Ok({})')],
  ['objects sql setup (sql_run! of the tables)', async (t) => answer(await counter(t, 'sql_setup'), '[]')],
  ['objects sql_run! of an insert of 2 rows into a table with no index gives rows_written 2', async (t) =>
    answer(await counter(t, 'sql_run'), 'Ok({ rows_read: 0, rows_written: 2 })')],
  // PLAN.md 8d for object SQL: each kind of MODULES.md 5.1, with the text of D1 and no `D1_ERROR: `.
  ['objects SQL: a primary key gives Constraint PrimaryKey', async (t) => answer(await counter(t, 'sql_constraint/pk'), constraint('PrimaryKey', 'UNIQUE constraint failed: t.id'))],
  ['objects SQL: an insert that breaks a UNIQUE index gives Constraint Unique', async (t) => answer(await counter(t, 'sql_constraint/unique'), constraint('Unique', 'UNIQUE constraint failed: t.u'))],
  ['objects SQL: NOT NULL gives Constraint NotNull', async (t) => answer(await counter(t, 'sql_constraint/notnull'), constraint('NotNull', 'NOT NULL constraint failed: t.n'))],
  ['objects SQL: CHECK gives Constraint Check', async (t) => answer(await counter(t, 'sql_constraint/check'), constraint('Check', 'CHECK constraint failed: c >= 0'))],
  ['objects SQL: a foreign key gives Constraint ForeignKey', async (t) => answer(await counter(t, 'sql_constraint/fk'), constraint('ForeignKey', 'FOREIGN KEY constraint failed'))],
  ['objects SQL: a STRICT column gives Constraint Datatype', async (t) => answer(await counter(t, 'sql_constraint/datatype'), constraint('Datatype', 'cannot store TEXT value in INTEGER column s.v'))],
  ["objects SQL: a trigger RAISE(ABORT, 'label-conflict') gives Constraint Trigger", async (t) => answer(await counter(t, 'sql_constraint/trigger'), constraint('Trigger', 'label-conflict'))],
  ['objects SQL: a syntax error is SqlErr', async (t) => answer(await counter(t, 'sql_syntax'), 'Err(SqlErr({ message: "near \\"SELEC\\": syntax error at offset 0: SQLITE_ERROR", name: "Error" }))')],
  ['objects sql!: rows of the type of the call', async (t) => answer(await counter(t, 'sql_all'), 'Ok([{ id: 1, u: "a" }])')],
  ['objects sql!: the integer rules of D1 (an Int parameter as text, CAST(v AS TEXT) into an I64, BadData with no cast)', async (t) =>
    answer(await counter(t, 'sql_int'), 'cast=Ok([{ v: 9223372036854775807 }, { v: -2687166099708853831 }]) plain=Err(BadData("column v: integer above 2^53, use CAST(v AS TEXT)"))')],
  ['objects sql_rows!, sql_rows_with!: columns and Sql values', async (t) => {
    answer(await counter(t, 'sql_rows'), 'Ok({ columns: ["id", "u", "b", "r", "z"], rows: [[Int(1), Text("a"), Blob([1, 2, 3]), Real(1.5), Null]] })');
    answer(await counter(t, 'sql_rows_with'), 'Err(TooLarge)');
  }],
  ['objects sql! of 2 MiB of rows is TooLarge, sql_with! with max_bytes of 4 MiB gives the rows', async (t) =>
    answer(await counter(t, 'sql_big'), 'default=Err TooLarge two=Err TooLarge four=Ok rows=22 rows=Err TooLarge')],
  ['objects cells a1, a2, b1: list_with! with prefix "a" gives ["a1", "a2"]', async (t) =>
    answer(await counter(t, 'cells', 'cells'), 'prefix=Ok(["a1", "a2"]) all=Ok(["a1", "a2", "b1"]) after=Ok(["a2"])')],
  ['objects Object.Cell get!, set!, delete!', async (t) =>
    answer(await counter(t, 'cell', 'cell'), 'before=Err(NotFound) set=Ok({}) got=Ok(-9007199254740993) del=Ok({}) after=Err(NotFound)')],
  ['objects get_alarm! after set_alarm!(t) gives t (and the Io twins)', async (t) =>
    answer(await counter(t, 'alarm', 'alarm'), 'set=Ok({}) same=True twin=True del=Ok({}) after=Err(NotFound) set2=Ok({}) del2=Ok({})')],
  ['objects delete_all!: the table, the cell and the alarm are gone (and the twin)', async (t) => {
    const want = 'del=Ok({}) table=False cell=Err(NotFound) alarm=Err(NotFound)';
    answer(await counter(t, 'delete_all', 'del'), want);
    answer(await counter(t, 'delete_all', 'del2', '&twin=1'), want);
  }],
  // Cloudflare docs: before 2026-02-24, `deleteAll` keeps the alarm, so the module calls `deleteAlarm` first.
  ['objects delete_all! with a compatibility date before 2026-02-24', async (t) => {
    const mf = t.start({ compatibilityDate: '2025-06-01', durableObjects });
    try {
      const res = await mf.dispatchFetch('http://localhost/objects/counter/delete_all?name=old');
      answer({ status: res.status, body: await res.text() }, 'del=Ok({}) table=False cell=Err(NotFound) alarm=Err(NotFound)');
    } finally {
      await mf.dispose();
    }
  }],
  ['objects id! of a named stub equals self.id in the object', async (t) => has(await t.get('/objects/id?name=x'), 'same=True')],
  ['objects jurisdiction(Eu): id! gives ObjectErr in Miniflare', async (t) =>
    answer(await t.get('/objects/jurisdiction?name=x'), 'Err(ObjectErr({ message: "Jurisdiction restrictions are not implemented in workerd.", name: "Error" }))')],
  ['objects named_with and from_id_with with location_hint, unique!', async (t) => answer(await t.get('/objects/location?name=loc'), 'same=True unique=True len=64')],
  ['objects fetch (Io twin)', async (t) => {
    const r = await t.get('/objects/fetch_io?name=x');
    ok(r.status === 200 && /^[0-9a-f]{64}$/.test(r.body), `got ${r.status} ${r.body}`);
  }],
  ['objects init! in blockConcurrencyWhile: two fetch! at the same time to a new object both read its table', async (t) =>
    answer(await t.get('/objects/store_pair?name=pair'), 'Ok([{ n: 0 }]) | Ok([{ n: 0 }])')],
  ['objects a class with no alarm!: set_alarm! gives StorageErr', async (t) =>
    answer(await t.get('/objects/store_alarm?name=na'), 'Err(StorageErr({ message: "Your Durable Object class must have an alarm() handler in order to call setAlarm()", name: "TypeError" }))')],
  ['objects the manifest: alarm only on a class with alarm!, the RPC methods on the prototype', async (t) => {
    const names = async (c) => JSON.parse((await t.get(`/__proto?class=${c}`)).body);
    const ticker = await names('Ticker'), store = await names('Store'), counterP = await names('Counter'), admin = await names('Admin'), dflt = await names('default');
    ok(ticker.includes('alarm') && ticker.includes('fetch'), `Ticker: ${ticker}`);
    ok(!store.includes('alarm') && store.includes('fetch'), `Store: ${store}`);
    for (const m of ['increment', 'ping', 'boom', 'echo', 'fetch', 'alarm']) ok(counterP.includes(m), `Counter has no ${m}: ${counterP}`);
    ok(admin.includes('purge') && admin.includes('fetch'), `Admin: ${admin}`);
    ok(dflt.includes('ping') && !dflt.includes('purge'), `default: ${dflt}`);
    // QO5: the app has queue!, email! and tail!, so the default export has the three methods (bench/entry-test.mjs 1b: without).
    for (const m of ['queue', 'email', 'tail']) ok(dflt.includes(m), `default has no ${m}: ${dflt}`);
    // PLAN.md 8f part 3: the socket handlers only on a class with them (Room of conformance/WebSocketRoutes.roc).
    const roomP = await names('Room');
    for (const m of ['webSocketMessage', 'webSocketClose', 'webSocketError', 'fetch']) ok(roomP.includes(m), `Room has no ${m}: ${roomP}`);
    for (const m of ['webSocketMessage', 'webSocketClose', 'webSocketError']) ok(!counterP.includes(m), `Counter has ${m}: ${counterP}`);
    return `Counter: ${counterP.join(' ')}; Store: ${store.join(' ')}`;
  }],
  ['objects init! that gives Err: ObjectErr, and the next fetch! runs init! again', async (t) => {
    const kv = await t.mf.getKVNamespace('OBJFLAGS');
    await kv.put('fail-init', '1');
    const first = await t.get('/objects/flaky?name=f1');
    has(first, 'Err ObjectErr');
    has(first, 'Flaky.init: failed: InitFailed');
    await kv.delete('fail-init');
    const second = await t.get('/objects/flaky?name=f1');
    ok(second.body.startsWith('ok '), `second: ${second.body}`);
    return `${first.body.slice(0, 120)} | ${second.body.slice(0, 20)}`;
  }],
  ['objects init! past the Init deadline is cancelled: ObjectErr with the name of the task', async (t) => {
    const r = await t.get('/objects/slow?name=s1');
    answer(r, 'Err ObjectErr({ message: "Slow.init: cancelled: deadline", name: "Error" })');
    ok(r.ms < 2500, `took ${r.ms} ms`);
    return `${r.ms} ms`;
  }],
  ['objects a KV-backed class: its first event names the class and new_sqlite_classes', async (t) => {
    const r = await t.get('/objects/kvonly?name=k');
    has(r, 'Err ObjectErr');
    has(r, 'Durable Object class KvOnly');
    has(r, 'new_sqlite_classes');
  }],
  ['objects respond! in the Fetch of an object: the response first, the cell after', async (t) => {
    answer(await t.get('/objects/respond?name=r'), 'early fast=True');
    await sleep(500);
    answer(await counter(t, 'late', 'r'), 'Ok("written")');
  }],
  ['objects pass_through! in the Fetch of an object is InvalidState', async (t) => answer(await counter(t, 'pass_through', 'pt'), 'Err(InvalidState)')],
  // RPC on a stub (MODULES.md 8).
  ['objects rpc: call! and its twin with an Rpc constant on a stub', async (t) => answer(await t.get('/objects/rpc/increment?name=inc'), 'Ok(2) Ok(5)')],
  ['objects rpc: a callee that gives Err(Nope(3)): RpcErr with the message Nope(3)', async (t) =>
    answer(await t.get('/objects/rpc/boom?name=b'), 'Err(RpcErr({ message: "Nope(3)", name: "Error" }))')],
  ['objects rpc: an unknown method throws (RpcErr)', async (t) =>
    answer(await t.get('/objects/rpc/nothere?name=b'), 'Err(RpcErr({ message: "The RPC receiver does not implement the method \\"nothere\\".", name: "TypeError" }))')],
  ['objects rpc: a U64 of 2^60 in an argument and a reply comes back exact', async (t) => answer(await t.get('/objects/rpc/echo?name=b'), 'Ok({ big: 1152921504606846976 })')],
  // API.md AQ10: a class in Roc with no export, and an export with no class in Roc, stop the load with the name.
  ['objects load: a class in Roc with no export stops the load with its name', async (t) => {
    const entry = t.entry.replace("export const KvOnly = objectClass('KvOnly');", 'const KvOnly = null;');
    ok(entry !== t.entry, 'no export line to remove');
    return loadFails(t, entry, 'KvOnly');
  }],
  ['objects load: an export with no class in Roc stops the load with its name', async (t) => {
    const entry = t.entry.replace("export const Admin = entrypointClass('Admin');", "export const Admin = entrypointClass('Admin');\nexport const Ghost = objectClass('Ghost');");
    ok(entry !== t.entry, 'no line to add to');
    return loadFails(t, entry, 'Ghost');
  }],
  // The alarm started in the first check: Workers runs it again after each `Err` (2 s, then 4 s).
  ['objects alarm!: Err while retry_count < 2 runs 3 times, with retry_count and is_retry', async (t) => {
    for (let i = 0; i < 120 && ticks(t).length < 3; i++) await sleep(100);
    await sleep(300);
    const got = ticks(t).map((x) => `${x.retry_count} ${x.is_retry}`);
    eq(got.join(', '), '0 false, 1 true, 2 true', 'the runs');
    return got.join(', ');
  }],
];
