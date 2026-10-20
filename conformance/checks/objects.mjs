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
const sqlp = (t, c) => counter(t, `sql_params/${c}`);
const has = (r, part) => ok(r.status === 200 && r.body.includes(part), `got ${r.status} ${JSON.stringify(r.body.slice(0, 400))}, want a text with ${JSON.stringify(part)}`);
const ticks = (t) => t.logs.filter((l) => String(l.message).includes('"msg":"ticker alarm"')).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{'))));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const constraint = (kind, message) => `Err(Infra(Constraint({ kind: ${kind}, message: ${JSON.stringify(message)} })))`;

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
  ['objects SQL: a syntax error is SqlErr', async (t) => answer(await counter(t, 'sql_syntax'), 'Err(Infra(SqlErr({ message: "near \\"SELEC\\": syntax error at offset 0: SQLITE_ERROR", name: "Error" })))')],
  ['objects sql!: rows of the type of the call', async (t) => answer(await counter(t, 'sql_all'), 'Ok([{ id: 1, u: "a" }])')],
  ['objects sql!: the integer rules of D1 (an Int parameter as text, CAST(v AS TEXT) into an I64, BadData with no cast)', async (t) =>
    answer(await counter(t, 'sql_int'), 'cast=Ok([{ v: 9223372036854775807 }, { v: -2687166099708853831 }]) plain=Err(Infra(BadData("column v: integer of 2^53 or more, read it with CAST(v AS TEXT) into an I64, U64 or Id64 field")))')],
  // PLAN.md 8h item 3: parameters as an `Encodable` tuple or list for object SQL (conformance/ObjectRoutes.roc, `sql_params!`).
  ['objects SQL params: a tuple of (Str, I64, F64, blob) is stored as text, integer, real, blob', async (t) =>
    answer(await sqlp(t, 'tuple'), 'Ok([{ a: "héllo", b: 42, c: 1.5, hd: "010203", ta: "text", tb: "integer", tc: "real", td: "blob" }])')],
  ['objects SQL params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x', async (t) =>
    answer(await sqlp(t, 'null'), 'ok=Ok([{ an: 1, b: 7, cn: 0, tb: "integer" }]) err=Ok([{ an: 1, b: -1, cn: 1, tb: "null" }])')],
  ['objects SQL params: a U64 of 2^63 - 1 is stored exact, 2^63 is BadParam and stores no row', async (t) => {
    answer(await sqlp(t, 'u64max'), 'Ok([{ t: "integer", v: "9223372036854775807" }])');
    const r = await sqlp(t, 'u64over');
    ok(r.body.includes('SqlErr') && r.body.includes('name: "BadParam"') && r.body.includes('the integer 9223372036854775808 does not fit I64'), `got ${r.body}`);
    answer(await counter(t, 'sql_params/count', 'sql'), 'n=0');
  }],
  ['objects SQL params: 2^53 + 1 binds as text and lands as the exact integer', async (t) =>
    answer(await sqlp(t, 'p53'), 'Ok([{ t: "integer", v: "9007199254740993" }])')],
  ['objects SQL params: a record and {} are BadParam; a tag item is BadParam with the hint; a Bool item is BadParam', async (t) => {
    for (const c of ['record', 'empty_record']) {
      const r = await sqlp(t, c);
      ok(r.body.includes('name: "BadParam"') && r.body.includes('SQL parameters must be a list or a tuple, not a record or a tag'), `${c}: got ${r.body}`);
    }
    has(await sqlp(t, 'tag_item'), 'SQL parameter 1: a record or a tag is not a SQL value, tag values are not SQL values, use Sql.null or Sql.or_null for NULL');
    has(await sqlp(t, 'bool'), 'SQL parameter 1: a Bool is not a SQL value, use 0 or 1');
    has(await sqlp(t, 'bool'), 'name: "BadParam"');
  }],
  ['objects SQL params: Sql.none and [x] are parameter lists', async (t) => {
    answer(await sqlp(t, 'none'), 'Ok([{ id: 1 }])');
    answer(await sqlp(t, 'single'), 'Ok([{ t: "one" }])');
  }],
  ['objects SQL params: a run-time List(Sql) still works', async (t) =>
    answer(await sqlp(t, 'runtime_list'), 'Ok([{ a: "text", b: 5, c: 2.5, hd: "09", ta: "text", tb: "integer", tc: "real", td: "blob" }])')],
  ['objects sql_rows!, sql_rows_with!: columns and Sql values', async (t) => {
    answer(await counter(t, 'sql_rows'), 'Ok({ columns: ["id", "u", "b", "r", "z"], rows: [[Int(1), Text("a"), Blob([1, 2, 3]), Real(1.5), Null]] })');
    answer(await counter(t, 'sql_rows_with'), 'Err(Infra(TooLarge))');
  }],
  ['objects sql! of 2 MiB of rows is TooLarge, sql_with! with max_bytes of 4 MiB gives the rows', async (t) =>
    answer(await counter(t, 'sql_big'), 'default=Err Infra(TooLarge) two=Err Infra(TooLarge) four=Ok rows=22 rows=Err Infra(TooLarge)')],
  ['objects cells a1, a2, b1: list_with! with prefix "a" gives ["a1", "a2"]', async (t) =>
    answer(await counter(t, 'cells', 'cells'), 'prefix=Ok(["a1", "a2"]) all=Ok(["a1", "a2", "b1"]) after=Ok(["a2"])')],
  ['objects Object.Cell get!, set!, delete!', async (t) =>
    answer(await counter(t, 'cell', 'cell'), 'before=Err(NotFound) set=Ok({}) got=Ok(-9007199254740993) del=Ok({}) after=Err(NotFound)')],
  ['objects Object.Cell get_or!: the default, then the value', async (t) =>
    answer(await counter(t, 'cell_or', 'cell_or'), 'none=Ok(42) some=Ok(7)')],
  // N6: `find!` has `NotFound` as a value of the inner `Try`.
  ['objects Object.Cell find!: a missing cell is Ok(Err(NotFound)), a value Ok(Ok(v)), a value of another type Err(Infra(BadData))', async (t) => {
    const r = await counter(t, 'cell_find', 'cell_find');
    ok(r.status === 200 && r.body.startsWith('none=Ok(Err(NotFound)) some=Ok(Ok(7)) bad=Err(Infra(BadData('), `got ${r.status} ${r.body}`);
    return r.body.slice(0, 120);
  }],
  // N4: the bindings that the namespaces give to the manifest (the same values as the string form gave: the class name, `script`).
  ['objects namespace: the class value gives the class name, script is kept, namespace_remote gives the text class and the script', async (t) =>
    answer(await t.get('/objects/namespaces'),
      '[{ kind: "object", name: "COUNTERS", props: [("class", "Counter")] }, { kind: "object", name: "FAR2", props: [("class", "Store"), ("script", "other")] }, { kind: "object", name: "FAR", props: [("class", "Far"), ("script", "other")] }]')],
  ['objects Object.Cell get_or!: a value of another type is BadData, not the default', async (t) => {
    const r = await counter(t, 'cell_or_bad', 'cell_or_bad');
    ok(r.status === 200 && r.body.startsWith('Err(Infra(BadData('), `got ${r.status} ${r.body}`);
  }],
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
  // Local form: `ObjectErr` (workerd does not have jurisdictions). Edge form (`t.edge`, PLAN.md 11c, E15): an id that differs from
  // the id of the same name with no jurisdiction.
  ['objects jurisdiction(Eu): id! gives ObjectErr in Miniflare, a different id on the edge', async (t) => {
    const r = await t.get('/objects/jurisdiction?name=x');
    if (!t.edge) return answer(r, 'Err(Infra(ObjectErr({ message: "Jurisdiction restrictions are not implemented in workerd.", name: "Error" })))');
    const plain = /outside=Ok\("([0-9a-f]{64})"\)/.exec((await t.get('/objects/id?name=x')).body);
    const eu = /^Ok\("([0-9a-f]{64})"\)$/.exec(r.body);
    ok(plain && eu, `got ${r.body} and the id ${plain && plain[1]}`);
    ok(plain[1] !== eu[1], 'the id with the jurisdiction equals the id with none');
  }],
  ['objects named_with and from_id_with with location_hint, unique!', async (t) => answer(await t.get('/objects/location?name=loc'), 'same=True unique=True len=64')],
  ['objects fetch (Io twin)', async (t) => {
    const r = await t.get('/objects/fetch_io?name=x');
    ok(r.status === 200 && /^[0-9a-f]{64}$/.test(r.body), `got ${r.status} ${r.body}`);
  }],
  ['objects init! in blockConcurrencyWhile: two fetch! at the same time to a new object both read its table', async (t) =>
    answer(await t.get('/objects/store_pair?name=pair'), 'Ok([{ n: 0 }]) | Ok([{ n: 0 }])')],
  ['objects a class with no alarm!: set_alarm! gives StorageErr', async (t) =>
    answer(await t.get('/objects/store_alarm?name=na'), 'Err(Infra(StorageErr({ message: "Your Durable Object class must have an alarm() handler in order to call setAlarm()", name: "TypeError" })))')],
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
    has(first, 'Err Infra(ObjectErr(');
    has(first, 'Flaky.init: failed: InitFailed');
    await kv.delete('fail-init');
    const second = await t.get('/objects/flaky?name=f1');
    ok(second.body.startsWith('ok '), `second: ${second.body}`);
    return `${first.body.slice(0, 120)} | ${second.body.slice(0, 20)}`;
  }],
  ['objects init! past the Init deadline is cancelled: ObjectErr with the name of the task', async (t) => {
    const r = await t.get('/objects/slow?name=s1');
    answer(r, 'Err Infra(ObjectErr({ message: "Slow.init: cancelled: deadline", name: "Error" }))');
    // The deadline is 1 s and init! sleeps 6 s: a cancel at the deadline, with room for a slow load.
    ok(r.ms < 4500, `took ${r.ms} ms`);
    return `${r.ms} ms`;
  }],
  ['objects a KV-backed class: its first event names the class and new_sqlite_classes', async (t) => {
    const r = await t.get('/objects/kvonly?name=k');
    has(r, 'Err Infra(ObjectErr(');
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
  ['objects rpc: a callee that gives Err(Nope(3)): the caller gets Err(Remote(Nope(3)))', async (t) =>
    answer(await t.get('/objects/rpc/boom?name=b'), 'Err(Remote(Nope(3)))')],
  ['objects rpc: an unknown method throws (RpcErr)', async (t) =>
    answer(await t.get('/objects/rpc/nothere?name=b'), 'Err(Infra(RpcErr({ message: "The RPC receiver does not implement the method \\"nothere\\".", name: "TypeError" })))')],
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
  // `set_alarm_in!` (MODULES.md 7): the alarm is `delay` after the call (`pf.alarmIn` adds `Date.now()`), not at once. `alarm!` logs "counter alarm".
  ['objects set_alarm_in! and its Io twin: get_alarm! is about now + delay, and the alarm fires after the delay, not at once', async (t) => {
    const alarmLogs = (id) => t.logs.filter((l) => String(l.message).includes('"msg":"counter alarm"')).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{')))).filter((l) => l.id === id);
    for (const [twin, name] of [['0', 'ain1'], ['1', 'ain2']]) {
      const t1 = Date.now();
      const r = await counter(t, 'alarm_in', name, `&ms=1500&twin=${twin}`);
      const t2 = Date.now();
      const m = /^set=Ok\(\{\}\) id=(\w+) t0=(\d+) alarm=Ok\((\d+)\)$/.exec(r.body);
      ok(m, `the answer: ${r.body}`);
      const [id, t0, alarm] = [m[1], Number(m[2]), Number(m[3])];
      ok(alarm >= t0 + 1500 && alarm <= t2 + 1500, `get_alarm! ${alarm}, want ${t0 + 1500} to ${t2 + 1500}`);
      ok(alarm >= t1 + 1500 - 50, `get_alarm! ${alarm} is not about now + 1500 (${t1 + 1500})`);
      eq(alarmLogs(id).length, 0, 'the alarm has not fired at once');
      await sleep(600);
      eq(alarmLogs(id).length, 0, 'the alarm has not fired 600 ms after the call');
      for (let i = 0; i < 100 && !alarmLogs(id).length; i++) await sleep(50);
      const fired = alarmLogs(id)[0];
      ok(fired, 'the alarm fired');
      ok(fired.at >= t0 + 1500 - 50, `fired at ${fired.at}, before the delay (t0 ${t0})`);
    }
  }],
  ['objects set_alarm_at!: get_alarm! gives the time, and the alarm fires at it', async (t) => {
    const logs = (id) => t.logs.filter((l) => String(l.message).includes('"msg":"counter alarm"')).map((l) => JSON.parse(String(l.message).slice(String(l.message).indexOf('{')))).filter((l) => l.id === id);
    const r = await counter(t, 'alarm_at', 'aat', '&ms=1000');
    const m = /^set=Ok\(\{\}\) id=(\w+) t=(\d+) alarm=Ok\((\d+)\)$/.exec(r.body);
    ok(m, `the answer: ${r.body}`);
    eq(m[3], m[2], 'get_alarm! is the time that was set');
    for (let i = 0; i < 100 && !logs(m[1]).length; i++) await sleep(50);
    const fired = logs(m[1])[0];
    ok(fired && fired.at >= Number(m[2]) - 50, `fired ${JSON.stringify(fired)}, want at ${m[2]} or later`);
  }],
];
