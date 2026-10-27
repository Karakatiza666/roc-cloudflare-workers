// `D1` and `Sql` (MODULES.md 5.1): routes of conformance/D1Routes.roc on the local D1 database `DB` of Miniflare. The
// first check makes the tables (with the binding of Miniflare, not with the module). Each check gives the text that
// the route answered. The constraint checks are the local part of PLAN.md 8d: the edge part is for 11c.
import { answer, eq, ok } from '../assert.mjs';

export const options = { d1Databases: ['DB'] };

const q = encodeURIComponent;
const route = (t, name, sql, p = '', extra = '') => t.get(`/d1/${name}?sql=${q(sql)}&p=${q(p)}${extra}`);
const P53 = 2n ** 53n;
const I64_MAX = 2n ** 63n - 1n;

// The JS `name` and `message` of each constraint failure (PLAN.md 8d: the docs do not give them). `bench/README.md` has them.
export const seen = {};

export const checks = [
  ['d1 setup (the tables, with the binding of Miniflare)', async (t) => {
    const db = await t.mf.getD1Database('DB');
    for (const sql of [
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)',
      "INSERT INTO people (id, name) VALUES (1, 'ann'), (2, 'bob'), (3, 'cy')",
      'CREATE TABLE ints (k TEXT PRIMARY KEY, v INTEGER)',
      'CREATE TABLE bigids (k INTEGER PRIMARY KEY, id INTEGER)',
      'CREATE TABLE nums (k INTEGER PRIMARY KEY, i INTEGER, x REAL)',
      'CREATE TABLE release (grp TEXT, version TEXT)',
      'CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)',
      'CREATE TABLE blobs (x TEXT)',
      'CREATE TABLE rid (id INTEGER PRIMARY KEY, v TEXT)',
      'CREATE TABLE pt (k TEXT, a, b INTEGER, c, d)',
      'CREATE TABLE pi (k TEXT PRIMARY KEY, v INTEGER)',
      'CREATE TABLE p (id INTEGER PRIMARY KEY)',
      'CREATE TABLE t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL, c INTEGER CHECK (c >= 0), p INTEGER REFERENCES p(id))',
      'CREATE TABLE s (id INTEGER PRIMARY KEY, v INTEGER) STRICT',
      "CREATE TRIGGER g BEFORE INSERT ON t WHEN NEW.id = 99 BEGIN SELECT RAISE(ABORT, 'label-conflict'); END",
      "CREATE TRIGGER g3 BEFORE INSERT ON t WHEN NEW.id = 97 BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: x'); END",
      "INSERT INTO t (id, u, n, c) VALUES (1, 'a', 1, 1)",
    ]) await db.prepare(sql).run();
    const big = [I64_MAX, -I64_MAX, -2687166099708853831n];
    for (let i = 0; i < big.length; i++) await db.prepare('INSERT INTO bigids (k, id) VALUES (?, CAST(? AS INTEGER))').bind(i, String(big[i])).run();
    await db.prepare('INSERT INTO nums (k, i, x) VALUES (1, ?, ?)').bind(Number(P53 - 1n), 2 ** 60).run();
    // 12 rows of 100,000 bytes: 1.2 MB of rows, above the 1 MiB limit of MC11.
    for (let i = 0; i < 12; i++) await db.prepare('INSERT INTO blobs (x) VALUES (?)').bind('x'.repeat(100000)).run();
  }],
  // PLAN.md 8c: `all!` gives rows of the type of the call; a query with 3 rows gives 3 rows.
  ['d1 all!', async (t) => {
    const r = await route(t, 'all', 'SELECT id, name FROM people ORDER BY id');
    answer(r, 'Ok [{ id: 1, name: "ann" }, { id: 2, name: "bob" }, { id: 3, name: "cy" }]');
    eq(r.waits, 1, 'waits');
  }],
  ['d1 all (Io twin), all_with! and twin', async (t) => {
    const want = 'Ok [{ id: 1, name: "ann" }, { id: 2, name: "bob" }, { id: 3, name: "cy" }]';
    answer(await route(t, 'all_io', 'SELECT id, name FROM people ORDER BY id'), want);
    answer(await route(t, 'all_with', 'SELECT id, name FROM people ORDER BY id', '', '&max=1000'), want);
    answer(await route(t, 'all_with_io', 'SELECT id, name FROM people ORDER BY id', '', '&max=1000'), want);
  }],
  ['d1 first!: a row, and NotFound for no row', async (t) => {
    answer(await route(t, 'first', 'SELECT id, name FROM people WHERE id = ?', 'i:2'), 'Ok { id: 2, name: "bob" }');
    answer(await route(t, 'first', 'SELECT id, name FROM people WHERE id = ?', 'i:9'), 'Err NotFound');
    answer(await route(t, 'first_io', 'SELECT id, name FROM people WHERE id = ?', 'i:9'), 'Err NotFound');
    answer(await route(t, 'first_with', 'SELECT id, name FROM people WHERE id = ?', 'i:3', '&max=1000'), 'Ok { id: 3, name: "cy" }');
    answer(await route(t, 'first_with_io', 'SELECT id, name FROM people WHERE id = ?', 'i:3', '&max=1000'), 'Ok { id: 3, name: "cy" }');
  }],
  ['d1 run!, run (Io twin): the info of an insert; last_row_id Ok(5)', async (t) => {
    answer(await route(t, 'run', 'INSERT INTO rid (id, v) VALUES (?, ?)', 'i:5,t:five'), 'Ok changes=1 last_row_id=Ok(5) rows_read=1 rows_written=1');
    answer(await route(t, 'run_io', 'INSERT INTO rid (id, v) VALUES (?, ?)', 'i:6,t:six'), 'Ok changes=1 last_row_id=Ok(6) rows_read=1 rows_written=1');
  }],
  // MODULES.md 5.1: D1 gives `meta.last_row_id` rounded for a rowid of size 2^53 or more.
  ['d1 run!: last_row_id of a 64-bit rowid is Err(Rounded)', async (t) => {
    answer(await route(t, 'run', 'INSERT INTO rid (id, v) VALUES (?, ?)', 'i:-2687166099708853831,t:big'), 'Ok changes=1 last_row_id=Err(Rounded) rows_read=1 rows_written=1');
  }],
  ['d1 rows!, rows (Io twin), rows_with!: columns and Sql values', async (t) => {
    const want = 'Ok { columns: ["id", "name"], rows: [[Int(1), Text("ann")], [Int(2), Text("bob")]] }';
    answer(await route(t, 'rows', 'SELECT id, name FROM people WHERE id < 3 ORDER BY id'), want);
    answer(await route(t, 'rows_io', 'SELECT id, name FROM people WHERE id < 3 ORDER BY id'), want);
    answer(await route(t, 'rows_with', 'SELECT id, name FROM people WHERE id < 3 ORDER BY id', '', '&max=1000'), want);
    answer(await route(t, 'rows_with_io', 'SELECT id, name FROM people WHERE id < 3 ORDER BY id', '', '&max=1000'), want);
    // A blob, a real, a null, and a 64-bit integer with no cast (an f64: Real).
    answer(await route(t, 'rows', "SELECT x'0102' AS b, 1.5 AS r, NULL AS n, id FROM bigids WHERE k = 0"), 'Ok { columns: ["b", "r", "n", "id"], rows: [[Blob([1, 2]), Real(1.5), Null, Real(9.223372036854776e18)]] }');
  }],
  ['d1 exec!, exec (Io twin)', async (t) => {
    answer(await route(t, 'exec', 'CREATE TABLE e1 (a INTEGER); INSERT INTO e1 VALUES (1)'), 'Ok {}');
    answer(await route(t, 'exec_io', 'INSERT INTO e1 VALUES (2)'), 'Ok {}');
    answer(await route(t, 'all', 'SELECT count(*) AS n FROM e1', '', '&type=count'), 'Ok [{ n: 2 }]');
  }],
  // PLAN.md 8c: an `Int` of 2^53 + 1 and of -(2^53 + 1) stores the exact value: it goes as text (5.1, "Parameters").
  ['d1 an Int parameter outside ±(2^53 - 1) stores the exact value', async (t) => {
    for (const [k, v] of [['pos', P53 + 1n], ['neg', -(P53 + 1n)], ['max', I64_MAX]]) {
      const r = await route(t, 'run', 'INSERT INTO ints (k, v) VALUES (?, ?)', `t:${k},i:${v}`);
      ok(r.body.startsWith('Ok changes=1 '), `insert ${k}: got ${r.body}`);
      answer(await route(t, 'first', 'SELECT CAST(v AS TEXT) AS t FROM ints WHERE k = ?', `t:${k}`, '&type=text'), `Ok { t: "${v}" }`);
    }
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare("SELECT typeof(v) AS ty FROM ints WHERE k = 'neg'").first()).ty, 'integer', 'the type in SQLite');
    return 'pos, neg and 2^63 - 1 read back exact, and SQLite has an integer';
  }],
  // MODULES.md 5.1, "Integers in rows": `CAST(id AS TEXT)` into an I64 field.
  ['d1 all! of CAST(id AS TEXT) into { id : I64 } gives the exact ids', async (t) => {
    answer(await route(t, 'all', 'SELECT CAST(id AS TEXT) AS id FROM bigids ORDER BY k', '', '&type=id'),
      'Ok [{ id: 9223372036854775807 }, { id: -9223372036854775807 }, { id: -2687166099708853831 }]');
  }],
  // MODULES.md 5.1, "Ids: Id64": ids above 2^63 (as U64) read from CAST text, given back as SQL parameters (the CBOR encoder of
  // `Id64` writes the I64 text, which binds as text), stored exact, shown as U64 text for JSON.
  ['d1 Id64: CAST text into an Id64 field, written back with the Id64 as a SQL parameter (CBOR I64 text), JSON as U64 text', async (t) => {
    answer(await t.get('/d1/id64?k=1'), 'Ok i64=-9223372036854775807 u64=9223372036854775809 same=True json={"id":"9223372036854775809"}');
    answer(await t.get('/d1/id64?k=2'), 'Ok i64=-2687166099708853831 u64=15759577974000697785 same=True json={"id":"15759577974000697785"}');
    answer(await t.get('/d1/id64?k=0'), 'Ok i64=9223372036854775807 u64=9223372036854775807 same=True json={"id":"9223372036854775807"}');
    const db = await t.mf.getD1Database('DB');
    // SQLite holds the exact integers (a U64 text would have become a REAL).
    const rows = (await db.prepare("SELECT CAST(id AS TEXT) AS id, typeof(id) AS ty FROM rid WHERE v = 'id64' ORDER BY id").all()).results;
    eq(JSON.stringify(rows), JSON.stringify([['-2687166099708853831'], ['-9223372036854775807'], ['9223372036854775807']].map(([id]) => ({ id, ty: 'integer' }))), 'the stored ids');
  }],
  ['d1 all! with no cast: BadData with the column, for a positive and a negative id', async (t) => {
    answer(await route(t, 'all', 'SELECT id FROM bigids WHERE k = 0', '', '&type=id'), 'Err Infra(BadData("column id: integer of 2^53 or more, read it with CAST(id AS TEXT) into an I64, U64 or Id64 field"))');
    answer(await route(t, 'all', 'SELECT id FROM bigids WHERE k = 2', '', '&type=id'), 'Err Infra(BadData("column id: integer of 2^53 or more, read it with CAST(id AS TEXT) into an I64, U64 or Id64 field"))');
    answer(await route(t, 'first', 'SELECT id FROM bigids WHERE k = 1', '', '&type=id'), 'Err Infra(BadData("column id: integer of 2^53 or more, read it with CAST(id AS TEXT) into an I64, U64 or Id64 field"))');
  }],
  ['d1 D1.Result.first of a batch! with no cast: BadData with the column', async (t) => {
    answer(await t.get(`/d1/batch_first?type=id&sql=${q('SELECT id FROM bigids WHERE k = 2')}`), 'Err Infra(BadData("column id: integer of 2^53 or more, read it with CAST(id AS TEXT) into an I64, U64 or Id64 field"))');
    answer(await t.get(`/d1/batch_first?type=id&sql=${q('SELECT CAST(id AS TEXT) AS id FROM bigids WHERE k = 2')}`), 'Ok { id: -2687166099708853831 }');
  }],
  ["d1 the text '01' and '9223372036854775808' into an I64 field give BadData", async (t) => {
    answer(await route(t, 'all', "SELECT '01' AS id", '', '&type=id'), 'Err Infra(BadData("column id: the value does not fit the type"))');
    answer(await route(t, 'all', "SELECT '9223372036854775808' AS id", '', '&type=id'), 'Err Infra(BadData("column id: the value does not fit the type"))');
  }],
  ['d1 a missing column gives BadData("column id: missing or NULL, ...")', async (t) => {
    answer(await route(t, 'all', 'SELECT name FROM people WHERE id = 1', '', '&type=id'), 'Err Infra(BadData("column id: missing or NULL, read a nullable column into id ?: a or Try(a, [Missing])"))');
  }],
  ['d1 an I64 column of 2^53 - 1 and an F64 column of 2^60 (no cast) read as numbers', async (t) => {
    answer(await route(t, 'first', 'SELECT i AS id FROM nums WHERE k = 1', '', '&type=id'), 'Ok { id: 9007199254740991 }');
    answer(await route(t, 'first', 'SELECT x FROM nums WHERE k = 1', '', '&type=real'), 'Ok { x_as_integer: Ok(1152921504606846976) }');
  }],
  // PLAN.md 8g P1: `all_tuples!` reads `raw()` into tuples. The tuple has one item for each column, in the order of the SELECT.
  ['d1 all_tuples!: rows as tuples, one crossing with a wait; no rows is Ok []', async (t) => {
    const r = await route(t, 'all_tuples', 'SELECT id, name FROM people ORDER BY id');
    answer(r, 'Ok [(1, "ann"), (2, "bob"), (3, "cy")]');
    eq(r.awaits, 1, 'crossings with a wait (js_await)');
    eq(r.calls, 0, 'crossings with no wait (js_call)');
    answer(await route(t, 'all_tuples', 'SELECT id, name FROM people WHERE id = ?', 'i:9'), 'Ok []');
    answer(await route(t, 'all_tuples', 'SELECT name, id FROM people WHERE id = 1'), 'Err Infra(BadData("column 0 (from 0): the value does not fit the type"))');
  }],
  ['d1 all_tuples (Io twin), all_tuples_with! and twin', async (t) => {
    const want = 'Ok [(1, "ann"), (2, "bob"), (3, "cy")]';
    answer(await route(t, 'all_tuples_io', 'SELECT id, name FROM people ORDER BY id'), want);
    answer(await route(t, 'all_tuples_with', 'SELECT id, name FROM people ORDER BY id', '', '&max=1000'), want);
    answer(await route(t, 'all_tuples_with_io', 'SELECT id, name FROM people ORDER BY id', '', '&max=1000'), want);
  }],
  ['d1 all_tuples! on a D1.Session: all four forms', async (t) => {
    const want = 'Ok [(1, "ann"), (2, "bob")]';
    for (const how of ['', '_io', '_with', '_with_io']) answer(await route(t, 'session_tuples', 'SELECT id, name FROM people WHERE id < 3 ORDER BY id', '', `&how=${how}&max=1000`), want);
  }],
  ['d1 all_tuples! on a D1.Session: rows above 1 MiB are TooLarge, all_tuples_with! with 2 MiB gives the rows', async (t) => {
    const sql = 'SELECT 1, x FROM blobs';
    answer(await route(t, 'session_tuples', sql, '', '&type=big&how='), 'Err Infra(TooLarge)');
    answer(await route(t, 'session_tuples', sql, '', '&type=big&how=_io'), 'Err Infra(TooLarge)');
    answer(await route(t, 'session_tuples', sql, '', `&type=big&how=_with&max=${2 * 1024 * 1024}`), 'Ok rows=12');
    answer(await route(t, 'session_tuples', sql, '', `&type=big&how=_with_io&max=${2 * 1024 * 1024}`), 'Ok rows=12');
  }],
  // MODULES.md 5.1, "Integers in rows", for tuples: the column is named by its index, from 0.
  ['d1 all_tuples! of CAST(id AS TEXT) into an I64 item gives the exact ids', async (t) => {
    answer(await route(t, 'all_tuples', 'SELECT k, CAST(id AS TEXT) FROM bigids ORDER BY k', '', '&type=ids'),
      'Ok [(0, 9223372036854775807), (1, -9223372036854775807), (2, -2687166099708853831)]');
  }],
  ['d1 all_tuples! with no cast: BadData with the column index, for a positive and a negative id', async (t) => {
    const bad = (c) => `Err Infra(BadData("column ${c} (from 0): integer of 2^53 or more, read it with CAST(... AS TEXT) into an I64, U64 or Id64 field"))`;
    answer(await route(t, 'all_tuples', 'SELECT k, id FROM bigids WHERE k = 0', '', '&type=ids'), bad(1));
    answer(await route(t, 'all_tuples', 'SELECT k, id FROM bigids WHERE k = 2', '', '&type=ids'), bad(1));
    answer(await route(t, 'all_tuples', 'SELECT id, k FROM bigids WHERE k = 1', '', '&type=ids'), bad(0));
  }],
  ["d1 all_tuples! the text '01' and '9223372036854775808' into an I64 item give BadData", async (t) => {
    const bad = 'Err Infra(BadData("column 1 (from 0): the value does not fit the type"))';
    answer(await route(t, 'all_tuples', "SELECT 1, '01'", '', '&type=ids'), bad);
    answer(await route(t, 'all_tuples', "SELECT 1, '9223372036854775808'", '', '&type=ids'), bad);
  }],
  ['d1 all_tuples! an I64 item of 2^53 - 1 and an F64 item of 2^60 (no cast) read as numbers', async (t) => {
    answer(await route(t, 'all_tuples', 'SELECT k, i FROM nums WHERE k = 1', '', '&type=ids'), 'Ok [(1, 9007199254740991)]');
    answer(await route(t, 'all_tuples', 'SELECT k, x FROM nums WHERE k = 1', '', '&type=reals'), 'Ok [(1, Ok(1152921504606846976))]');
  }],
  ['d1 all_tuples! into a record type is BadData (a row is an array)', async (t) => {
    const r = await route(t, 'all_tuples', 'SELECT id, name FROM people ORDER BY id', '', '&type=record');
    ok(r.status === 200 && r.body.startsWith('Err Infra(BadData('), `got ${r.status} ${r.body}`);
    return r.body;
  }],
  ['d1 all_tuples! of rows above 1 MiB is TooLarge, all_tuples_with! with max_bytes of 2 MiB gives the rows', async (t) => {
    answer(await route(t, 'all_tuples', 'SELECT 1, x FROM blobs', '', '&type=big'), 'Err Infra(TooLarge)');
    answer(await route(t, 'all_tuples_with', 'SELECT 1, x FROM blobs', '', `&type=big&max=${2 * 1024 * 1024}`), 'Ok rows=12');
  }],
  // PLAN.md 8c: 2 inserts and a select in one batch: 3 results, and `first()` of the third reads the count. One crossing.
  ['d1 batch! of 2 inserts and a select: 3 results, first() of the third reads the count; one crossing', async (t) => {
    const r = await t.get('/d1/batch_count?grp=g1');
    answer(r, 'Ok results=3 written=1,1 count=Ok({ n: 2 }) all=Ok([{ n: 2 }])');
    eq(r.awaits, 1, 'crossings with a wait (js_await)');
    eq(r.calls, 0, 'crossings with no wait (js_call)');
    return `${r.awaits} js_await, ${r.calls} js_call`;
  }],
  ['d1 batch (Io twin), batch_with! and twin', async (t) => {
    const sql = 'SELECT 1 AS n;SELECT 2 AS n';
    for (const name of ['batch', 'batch_io', 'batch_with', 'batch_with_io']) {
      const r = await route(t, name, sql, '', '&max=1000');
      ok(r.status === 200 && r.body.startsWith('Ok results=2 '), `${name}: got ${r.body}`);
    }
  }],
  // MC11: a read above the limit is TooLarge, before any copy into wasm.
  ['d1 all! of rows above 1 MiB is TooLarge, all_with! with max_bytes of 2 MiB gives the rows', async (t) => {
    answer(await route(t, 'all', 'SELECT x FROM blobs', '', '&type=big'), 'Err Infra(TooLarge)');
    answer(await route(t, 'all_with', 'SELECT x FROM blobs', '', `&type=big&max=${2 * 1024 * 1024}`), 'Ok rows=12');
    answer(await route(t, 'rows', 'SELECT x FROM blobs'), 'Err Infra(TooLarge)');
    ok((await route(t, 'rows_with', 'SELECT x FROM blobs', '', `&max=${2 * 1024 * 1024}`)).body.startsWith('Ok { columns: ["x"]'), 'rows_with! with 2 MiB');
    answer(await route(t, 'batch', 'SELECT x FROM blobs WHERE rowid <= 6;SELECT x FROM blobs WHERE rowid > 6'), 'Err Infra(TooLarge)');
    ok((await route(t, 'batch_with', 'SELECT x FROM blobs WHERE rowid <= 6;SELECT x FROM blobs WHERE rowid > 6', '', `&max=${2 * 1024 * 1024}`)).body.startsWith('Ok results=2 '), 'batch_with! with 2 MiB');
  }],
  // PLAN.md 8c: `with_session!(Primary)`: NotFound before a query, Ok after an insert, and `After(bookmark)` reads the row.
  ['d1 with_session!: bookmark! before and after a query, and After(bookmark)', async (t) => {
    const r = await t.get('/d1/session?k=s1');
    const m = /^before=Err\(NotFound\) insert=Ok\(\{\}\) after=(\S+)$/.exec(r.body);
    ok(r.status === 200 && m && m[1] !== 'none' && m[1] !== '', `got ${r.status} ${r.body}`);
    answer(await t.get(`/d1/session_after?b=${q(m[1])}&k=s1`), 'Ok { t: "session" }');
    return `bookmark ${m[1]}`;
  }],
  // PLAN.md 8d: constraint failures (MODULES.md 5.1, table "Constraint kinds"). Each check keeps the JS text in `seen`.
  // V17 (2026-10-26): the tag is the flat `Constraint`, not `Infra(Constraint)`.
  ...[
    ['a primary key', 'PrimaryKey', "INSERT INTO t (id, u, n, c) VALUES (1, 'b', 1, 1)", 'UNIQUE constraint failed: t.id'],
    ['a UNIQUE column', 'Unique', "INSERT INTO t (id, u, n, c) VALUES (2, 'a', 1, 1)", 'UNIQUE constraint failed: t.u'],
    ['NOT NULL', 'NotNull', "INSERT INTO t (id, u, n, c) VALUES (3, 'c', NULL, 1)", 'NOT NULL constraint failed: t.n'],
    ['CHECK', 'Check', "INSERT INTO t (id, u, n, c) VALUES (4, 'd', 1, -1)", 'CHECK constraint failed: c >= 0'],
    ['a foreign key', 'ForeignKey', "INSERT INTO t (id, u, n, c, p) VALUES (5, 'e', 1, 1, 42)", 'FOREIGN KEY constraint failed'],
    ['a STRICT column', 'Datatype', "INSERT INTO s (id, v) VALUES (1, 'x')", 'cannot store TEXT value in INTEGER column s.v'],
    ["a trigger RAISE(ABORT, 'UNIQUE constraint failed: x')", 'Trigger', "INSERT INTO t (id, u, n, c) VALUES (97, 'y', 1, 1)", 'UNIQUE constraint failed: x'],
  ].map(([what, kind, sql, message]) => [`d1 8d: ${what} gives Constraint ${kind}`, async (t) => {
    answer(await route(t, 'run', sql), `Err Constraint({ kind: ${kind}, message: "${message}" })`);
    seen[kind] = await jsError(t, sql);
    return seen[kind];
  }]),
  ["d1 8d: a trigger RAISE(ABORT, 'label-conflict') in a batch! gives Trigger, and the batch writes nothing", async (t) => {
    const sql = "INSERT INTO t (id, u, n, c) VALUES (50, 'w', 1, 1);INSERT INTO t (id, u, n, c) VALUES (99, 'z', 1, 1)";
    answer(await route(t, 'batch', sql), 'Err Constraint({ kind: Trigger, message: "label-conflict" })');
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare('SELECT count(*) AS n FROM t WHERE id = 50').first()).n, 0, 'rows of the first insert');
    seen.batchTrigger = await jsError(t, null, sql);
    return seen.batchTrigger;
  }],
  ['d1 8d: exec! of a primary key failure gives PrimaryKey, with the line and the SQL in the message', async (t) => {
    const sql = "INSERT INTO t (id, u, n, c) VALUES (1, 'q', 1, 1)";
    answer(await route(t, 'exec', sql), `Err Constraint({ kind: PrimaryKey, message: "Error in line 1: ${sql}: UNIQUE constraint failed: t.id" })`);
  }],
  ['d1 a syntax error is D1Err', async (t) => {
    answer(await route(t, 'run', 'SELEC 1'), 'Err Infra(D1Err({ message: "D1_ERROR: near \\"SELEC\\": syntax error at offset 0: SQLITE_ERROR", name: "Error" }))');
  }],
  // PLAN.md 8h item 3: parameters are any value that encodes to a CBOR array (conformance/D1Routes.roc, `params!`).
  ['d1 params: a tuple of (Str, I64, F64, blob) is stored as text, integer, real, blob (run!, and its Io twin)', async (t) => {
    answer(await par(t, 'tuple'), 'Ok [{ a: "héllo", b: 42, c: 1.5, hd: "010203", ta: "text", tb: "integer", tc: "real", td: "blob" }]');
    answer(await par(t, 'tuple_io'), 'Ok [{ a: "x", b: 7, c: 2.5, hd: "FF", ta: "text", tb: "integer", tc: "real", td: "blob" }]');
  }],
  ['d1 params: Sql.null and Sql.or_null(Err _) store NULL, Sql.or_null(Ok x) stores x', async (t) => {
    answer(await par(t, 'null'), 'ok=Ok([{ an: 1, b: 7, cn: 0, tb: "integer" }]) err=Ok([{ an: 1, b: -1, cn: 1, tb: "null" }])');
  }],
  ['d1 params: a U64 of 2^63 - 1 is stored exact', async (t) => {
    answer(await par(t, 'u64max'), 'Ok [{ t: "integer", v: "9223372036854775807" }]');
  }],
  ['d1 params: a U64 of 2^63 is BadParam, and no row (never a negative number) is stored', async (t) => {
    const r = await par(t, 'u64over');
    ok(r.body.startsWith('Err Infra(D1Err({ message: "SQL parameter 1: the integer 9223372036854775808 does not fit I64"') && r.body.includes('name: "BadParam"'), `got ${r.body}`);
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare("SELECT count(*) AS n FROM pi WHERE k = 'u64over' OR v < 0").first()).n, 0, 'rows of the failed insert, or negative');
  }],
  ['d1 params: 2^53 + 1 (I64 and U64) and I64 min bind as text and land as the exact integer', async (t) => {
    answer(await par(t, 'p53'), 'Ok [{ t: "integer", v: "9007199254740993" }]');
    answer(await par(t, 'p53_u64'), 'Ok [{ t: "integer", v: "9007199254740993" }]');
    answer(await par(t, 'i64min'), 'Ok [{ t: "integer", v: "-9223372036854775808" }]');
  }],
  ['d1 params: a record and {} are BadParam (a list, a tuple or one value is needed)', async (t) => {
    for (const c of ['record', 'empty_record']) {
      const r = await par(t, c);
      ok(r.body.startsWith('Err Infra(D1Err({ message: "SQL parameters must be a list, a tuple or one value, not a record or a tag') && r.body.includes('name: "BadParam"'), `${c}: got ${r.body}`);
    }
  }],
  ['d1 params: a tag item is BadParam with the hint for Sql.or_null; a Bool item is BadParam', async (t) => {
    const e = await par(t, 'tag_item');
    ok(e.body.includes('name: "BadParam"') && e.body.includes('SQL parameter 1: a record or a tag is not a SQL value, tag values are not SQL values, use Sql.null or Sql.or_null for NULL'), `tag_item: got ${e.body}`);
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare("SELECT count(*) AS n FROM pi WHERE k = 'tag_item'").first()).n, 0, 'rows of the refused insert');
    const b = await par(t, 'bool');
    ok(b.body.includes('name: "BadParam"') && b.body.includes('SQL parameter 1: a Bool is not a SQL value, use 0 or 1'), `bool: got ${b.body}`);
    // FINDING: `Err(Null)` of a `Try(a, [Null])` encodes as CBOR null (roc-cbor), so it binds NULL. MODULES.md 5.1 says it is a map.
    await par(t, 'err_null');
    eq((await db.prepare("SELECT typeof(v) AS t FROM pi WHERE k = 'err_null'").first()).t, 'null', 'Err(Null) of Try(a, [Null])');
    // The same checks on a session and in a batch (Sql.stmt).
    ok((await par(t, 'bad_session')).body.includes('name: "BadParam"'), 'session');
    ok((await par(t, 'bad_batch')).body.includes('name: "BadParam"'), 'batch');
  }],
  ['d1 params: Sql.none and [x] are parameter lists', async (t) => {
    answer(await par(t, 'none'), 'Ok [{ id: 1 }]');
    answer(await par(t, 'single'), 'Ok [{ t: "one" }]');
  }],
  ['d1 params: batch! with Sql.stmt of different tuple types, and first() of a result', async (t) => {
    answer(await par(t, 'stmt_batch'), 'Ok changes=1,1,0 count=Ok({ n: 1 })');
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare("SELECT typeof(b) AS t FROM pt WHERE k = 'b2'").first()).t, 'null', 'Sql.null in a batch');
  }],
  ['d1 params: a run-time List(Sql) still works, and a session takes a tuple', async (t) => {
    answer(await par(t, 'runtime_list'), 'Ok [{ a: "text", b: 5, c: 2.5, hd: "09", ta: "text", tb: "integer", tc: "real", td: "blob" }]');
    answer(await par(t, 'session'), 'Ok { t: "sblob" }');
  }],
  // v2 probe finding V17: the natural pattern `Err(Constraint(..))` matches (a 409 of the route), in each D1 form that can
  // raise it. `Err(Infra(..))` is the rest (a 500).
  ['d1 V17: Err(Constraint(..)) matches a duplicate key in run!, first!, batch!, exec! and a session (a 409)', async (t) => {
    const want = () => 'Constraint PrimaryKey | UNIQUE constraint failed: kv.k';
    for (const c of ['run', 'first', 'batch', 'session']) {
      const r = await t.get(`/d1/conflict/${c}?k=v17-${c}`);
      eq(r.status, 409, `${c}: status (${r.body})`);
      eq(r.body, want(c), `${c}: body`);
    }
    const e = await t.get('/d1/conflict/exec?k=v17-exec');
    eq(e.status, 409, `exec: status (${e.body})`);
    ok(e.body.startsWith('Constraint PrimaryKey | Error in line 1: '), `exec: got ${e.body}`);
  }],
  ['d1 V17: a syntax error is still Infra(D1Err), not Constraint (a 500)', async (t) => {
    const r = await t.get('/d1/conflict/syntax?k=v17-syntax');
    eq(r.status, 500, `status (${r.body})`);
    ok(r.body.startsWith('Infra D1Err({ message: "D1_ERROR: near \\"VALUS\\": syntax error'), `got ${r.body}`);
  }],
  // v2 probe finding 28: a bare value that is not a list, a tuple or a record is one parameter (js/helpers.js `sqlParams`).
  ['d1 params: a bare Str, I64, Dec, Sql.null and Sql.blob are one parameter (all!, first!, run!)', async (t) => {
    answer(await par(t, 'bare_str'), 'Ok [{ t: "one" }]');
    answer(await par(t, 'bare_int'), 'Ok { id: 7 }');
    answer(await par(t, 'bare_dec'), 'Ok { id: 42 }');
    answer(await par(t, 'bare_null'), 'Ok { t: "null" }');
    answer(await par(t, 'bare_blob'), 'Ok { t: "blob:0102" }');
    answer(await par(t, 'bare_run'), 'Ok { t: "x" }');
  }],
  ['d1 params: a bare value in a session and in Sql.stmt of a batch', async (t) => {
    answer(await par(t, 'bare_session'), 'Ok { t: "in session" }');
    answer(await par(t, 'bare_batch'), 'Ok { t: "in batch" }');
  }],
  ['d1 params: a bare List(U8) is a list of parameters, not one blob; a bare Bool is BadParam as an item', async (t) => {
    answer(await par(t, 'bare_bytes'), 'Ok { columns: ["a", "b"], rows: [[Int(1), Int(2)]] }');
    const b = await par(t, 'bare_bool');
    ok(b.body.includes('name: "BadParam"') && b.body.includes('SQL parameter 0: a Bool is not a SQL value, use 0 or 1'), `got ${b.body}`);
  }],
  ['d1 params: the old Sql tag form ([Text("ann")], a bare Int(5), Blob in a tuple) is BadParam that names the new form', async (t) => {
    for (const [c, text] of [
      ['old_text', 'SQL parameter 0: Text(\\"ann\\") is the old Sql tag form, write \\"ann\\"'],
      ['old_int', 'SQL parameters: Int(5) is the old Sql tag form, write 5'],
      ['old_blob', 'SQL parameter 1: Blob([1, 2]) is the old Sql tag form, write Sql.blob([1, 2])'],
    ]) {
      const r = await par(t, c);
      ok(r.body.startsWith('Err Infra(D1Err({ message: ') && r.body.includes(text) && r.body.includes('name: "BadParam"'), `${c}: got ${r.body}`);
    }
    const db = await t.mf.getD1Database('DB');
    eq((await db.prepare("SELECT count(*) AS n FROM pi WHERE k IN ('old_text', 'old_int')").first()).n, 0, 'rows of the refused inserts');
  }],
  // v2 probe findings 30, 31 with roc-cbor 0.2.2: a NULL in a record is a missing key; a Bool reads 0 and 1.
  ['d1 reads: NULL into a Str field or a Try(Str, [Null]) field is BadData that names ?: and Try(a, [Missing])', async (t) => {
    const text = 'Err Infra(BadData("column t: missing or NULL, read a nullable column into t ?: a or Try(a, [Missing])"))';
    answer(await rd(t, 'null_str'), text);
    answer(await rd(t, 'null_try'), text);
  }],
  ['d1 reads: NULL into a Try(Str, [Missing]) field is Err(Missing)', async (t) => {
    answer(await rd(t, 'null_missing'), 'Ok [{ t: Err(Missing) }, { t: Ok("x") }]');
  }],
  ['d1 reads: an optional field reads a missing column and a NULL as absent', async (t) => {
    answer(await rd(t, 'opt_missing'), 'Ok { id: 1, nick: Err(MissingField) }');
    answer(await rd(t, 'opt_null'), 'Ok { id: 1, nick: Err(MissingField) }');
  }],
  ['d1 reads: a boolean column (0 or 1) into a Bool field is Ok; a U8 field reads it; 2 is BadData', async (t) => {
    answer(await rd(t, 'bool'), 'Ok [{ b: True }]');
    answer(await rd(t, 'bool_false'), 'Ok { b: False }');
    answer(await rd(t, 'bit'), 'Ok [{ b: 1 }, { b: 0 }]');
    answer(await rd(t, 'batch_bool'), 'Ok { b: True }');
    answer(await rd(t, 'bool_two'), 'Err Infra(BadData("column b: the value does not fit the type"))');
  }],
  ['d1 reads: all_tuples! of a NULL into a Str item is BadData that names the column index and Try(a, [Null])', async (t) => {
    answer(await rd(t, 'tuple_null'), 'Err Infra(BadData("column 1 (from 0): NULL, read it into a Try(a, [Null]) item"))');
  }],
];

const par = (t, c) => t.get(`/d1/params/${c}`);
const rd = (t, c) => t.get(`/d1/reads/${c}`);

// The `name: message` that the binding throws for `sql` (one statement), or for a batch of `batch` (split at `;`).
async function jsError(t, sql, batch) {
  const db = await t.mf.getD1Database('DB');
  try {
    if (batch) await db.batch(batch.split(';').map((s) => db.prepare(s)));
    else await db.prepare(sql).run();
    return 'no throw';
  } catch (e) {
    return `${e.name}: ${e.message}`;
  }
}
