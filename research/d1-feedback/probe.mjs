// Probe for the D1 design feedback: integers near 2^53, negative ids, and the error objects of constraint failures.
// Run: node probe.mjs   (Miniflare of the global wrangler of this node)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const script = `
const show = (e) => {
  const props = {};
  for (const k of Object.getOwnPropertyNames(e)) if (k !== 'stack') props[k] = String(e[k]);
  const cause = e.cause ? { name: e.cause.name, message: e.cause.message, props: Object.getOwnPropertyNames(e.cause).filter(k => k !== 'stack'),
    code: e.cause.code, extra: Object.fromEntries(Object.getOwnPropertyNames(e.cause).filter(k=>!['stack','message'].includes(k)).map(k=>[k,String(e.cause[k])])) } : null;
  return { name: e.name, message: e.message, ctor: e.constructor?.name, props, cause };
};
const tryIt = async (f) => { try { return { ok: await f() }; } catch (e) { return { err: show(e) }; } };
export class Obj {
  constructor(state) { this.sql = state.storage.sql; }
  async fetch(req) {
    const out = {};
    const s = this.sql;
    s.exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL, c INTEGER CHECK (c >= 0))");
    s.exec("CREATE TABLE IF NOT EXISTS big (id INTEGER)");
    s.exec("INSERT INTO big VALUES (?)", "9007199254740993");
    s.exec("INSERT INTO t (id, u, n, c) VALUES (1, 'a', 1, 1)");
    out.pk = await tryIt(() => s.exec("INSERT INTO t (id, u, n, c) VALUES (1, 'b', 1, 1)").toArray());
    out.unique = await tryIt(() => s.exec("INSERT INTO t (id, u, n, c) VALUES (2, 'a', 1, 1)").toArray());
    out.notnull = await tryIt(() => s.exec("INSERT INTO t (id, u, n, c) VALUES (3, 'c', NULL, 1)").toArray());
    out.check = await tryIt(() => s.exec("INSERT INTO t (id, u, n, c) VALUES (4, 'd', 1, -1)").toArray());
    s.exec("CREATE TRIGGER IF NOT EXISTS g BEFORE INSERT ON t WHEN NEW.id = 99 BEGIN SELECT RAISE(ABORT, 'label-conflict'); END");
    out.trigger = await tryIt(() => s.exec("INSERT INTO t (id, u, n, c) VALUES (99, 'z', 1, 1)").toArray());
    out.bigread = await tryIt(() => { const r = s.exec("SELECT id FROM big").toArray()[0].id; return [typeof r, String(r)]; });
    out.bigcast = await tryIt(() => s.exec("SELECT CAST(id AS TEXT) AS id FROM big").toArray()[0].id);
    out.bigint_bind = await tryIt(() => s.exec("SELECT ? AS x", 2n ** 60n).toArray());
    return Response.json(out);
  }
}
export default {
  async fetch(req, env) {
    if (new URL(req.url).pathname === '/do') return env.OBJ.get(env.OBJ.idFromName('x')).fetch(req);
    const db = env.DB;
    const out = {};
    await db.exec("CREATE TABLE p (id INTEGER PRIMARY KEY)");
    await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL, c INTEGER CHECK (c >= 0), p INTEGER REFERENCES p(id))");
    await db.exec("CREATE TABLE s (id INTEGER PRIMARY KEY, v INTEGER) STRICT");
    await db.exec("CREATE TABLE ids (id INTEGER)");
    await db.prepare("CREATE TRIGGER g BEFORE INSERT ON t WHEN NEW.id = 99 BEGIN SELECT RAISE(ABORT, 'label-conflict'); END").run();
    await db.prepare("CREATE TRIGGER g2 BEFORE INSERT ON t WHEN NEW.id = 98 BEGIN SELECT RAISE(FAIL, 'sweep-incomplete'); END").run();
    await db.prepare("CREATE TRIGGER g3 BEFORE INSERT ON t WHEN NEW.id = 97 BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: fake'); END").run();
    await db.prepare("INSERT INTO t (id, u, n, c) VALUES (1, 'a', 1, 1)").run();
    const ins = (id, u, n, c, p = null) => db.prepare("INSERT INTO t (id, u, n, c, p) VALUES (?, ?, ?, ?, ?)").bind(id, u, n, c, p);
    out.pk = await tryIt(() => ins(1, 'b', 1, 1).run());
    out.unique = await tryIt(() => ins(2, 'a', 1, 1).run());
    out.notnull = await tryIt(() => ins(3, 'c', null, 1).run());
    out.check = await tryIt(() => ins(4, 'd', 1, -1).run());
    out.fk = await tryIt(() => ins(5, 'e', 1, 1, 777).run());
    out.trigger_abort = await tryIt(() => ins(99, 'f', 1, 1).run());
    out.trigger_fail = await tryIt(() => ins(98, 'g', 1, 1).run());
    out.trigger_fake = await tryIt(() => ins(97, 'h', 1, 1).run());
    out.strict = await tryIt(() => db.prepare("INSERT INTO s (id, v) VALUES (1, 'x')").run());
    out.batch_pk = await tryIt(() => db.batch([ins(10, 'k', 1, 1), ins(1, 'l', 1, 1)]));
    out.batch_trigger = await tryIt(() => db.batch([ins(11, 'm', 1, 1), ins(99, 'n', 1, 1)]));
    out.exec_pk = await tryIt(() => db.exec("INSERT INTO t (id, u, n, c) VALUES (1, 'q', 1, 1)"));
    out.syntax = await tryIt(() => db.prepare("SELEC 1").run());
    out.bigint = await tryIt(() => db.prepare("SELECT ?").bind(2n ** 60n).run());
    // Integers: positive and negative near and above 2^53.
    const vals = ["9007199254740991", "9007199254740992", "9007199254740993", "-9007199254740991", "-9007199254740992", "-9007199254740993",
      "9223372036854775807", "-9223372036854775808", "-2687166099708853831"];
    for (const v of vals) await db.prepare("INSERT INTO ids (id) VALUES (?)").bind(v).run();
    out.ints = [];
    for (const v of vals) {
      const plain = (await db.prepare("SELECT id, typeof(id) AS t FROM ids WHERE id = ?").bind(v).first());
      const cast = (await db.prepare("SELECT CAST(id AS TEXT) AS s FROM ids WHERE id = ?").bind(v).first());
      const look = (await db.prepare("SELECT CAST(id AS TEXT) AS s FROM ids WHERE id = ?").bind(plain.id).all()).results.map(r => r.s);
      out.ints.push({ v, type: plain.t, plain: String(plain.id), js: typeof plain.id, safe: Number.isSafeInteger(plain.id), cast: cast.s, lookup_of_plain: look });
    }
    // A text parameter where it meets no column, and in a compare with a column.
    out.text_param = {
      two_params: (await db.prepare("SELECT ? = ? + 0 AS e").bind("-9007199254740993", "-9007199254740993").first()).e,
      typeof_param: (await db.prepare("SELECT typeof(?) AS t").bind("-9007199254740993").first()).t,
      col_eq: (await db.prepare("SELECT COUNT(*) AS n FROM ids WHERE id = ?").bind("-9007199254740993").first()).n,
      col_lt: (await db.prepare("SELECT COUNT(*) AS n FROM ids WHERE id < ?").bind("-9007199254740992").first()).n,
      expr: (await db.prepare("SELECT COUNT(*) AS n FROM ids WHERE id = ? + 0").bind("-9007199254740993").first()).n,
      number_neg: await tryIt(async () => { await db.prepare("INSERT INTO ids (id) VALUES (?)").bind(-9007199254740993).run();
        return (await db.prepare("SELECT CAST(id AS TEXT) AS s FROM ids WHERE rowid = last_insert_rowid()").first()).s; }),
      real_col: (await db.prepare("SELECT 1e20 AS r, 9007199254740993.0 AS r2, CAST('9007199254740993' AS INTEGER) AS i").first()),
    };
    return Response.json(out);
  }
};`;

const mf = new Miniflare(convertV4MiniflareOptions({
  modules: true, script, compatibilityDate: '2026-10-01',
  d1Databases: ['DB'], durableObjects: { OBJ: { className: 'Obj', useSQLite: true } },
}));
const r1 = await (await mf.dispatchFetch('http://x/')).text();
const r2 = await (await mf.dispatchFetch('http://x/do')).text();
console.log(JSON.stringify(JSON.parse(r1), null, 1));
console.log('--- DO');
console.log(JSON.stringify(JSON.parse(r2), null, 1));
await mf.dispose();
