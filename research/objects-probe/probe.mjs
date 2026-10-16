// The facts of local Durable Objects and RPC (Miniflare 5) that the design of PLAN.md 8f, part 1 needs: object SQL
// (cursor fields, integers, constraint texts), the sync KV API, alarms (retries, alarmInfo, no handler), a KV-backed
// class, deleteAll with an old compatibility date, ids and jurisdictions, blockConcurrencyWhile, service bindings to a
// named entry point, RPC errors.
//   node research/objects-probe/probe.mjs   (Miniflare of the global wrangler)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);

const script = `
import { DurableObject, WorkerEntrypoint } from 'cloudflare:workers';
const err = (e) => e.name + ': ' + e.message;
const kind = (v) => v === null ? 'null' : Array.isArray(v) ? 'Array' : v instanceof ArrayBuffer ? 'ArrayBuffer' : typeof v === 'object' ? (Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto') : typeof v;
const runs = [];
export class Sql extends DurableObject {
  async fetch(req) {
    const sql = this.ctx.storage.sql;
    const out = {};
    sql.exec('CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL, c INTEGER CHECK (c >= 0), p INTEGER REFERENCES p(id), b BLOB)');
    sql.exec('CREATE TABLE IF NOT EXISTS p (id INTEGER PRIMARY KEY)');
    sql.exec('CREATE TABLE IF NOT EXISTS s (id INTEGER PRIMARY KEY, v INTEGER) STRICT');
    sql.exec('CREATE TABLE IF NOT EXISTS noidx (a TEXT, b TEXT)');
    sql.exec("CREATE TRIGGER IF NOT EXISTS g BEFORE INSERT ON t WHEN NEW.id = 99 BEGIN SELECT RAISE(ABORT, 'label-conflict'); END");
    const c = sql.exec("INSERT INTO noidx (a, b) VALUES ('x', 'y'), ('z', 'w')");
    out.insertBeforeIter = { rowsRead: c.rowsRead, rowsWritten: c.rowsWritten, keys: Object.keys(c), proto: Object.getOwnPropertyNames(Object.getPrototypeOf(c)) };
    out.insertToArray = c.toArray();
    out.insertAfterIter = { rowsRead: c.rowsRead, rowsWritten: c.rowsWritten };
    sql.exec("INSERT INTO t (id, u, n, c, b) VALUES (1, 'a', 1, 1, ?)", new Uint8Array([1, 2, 3]));
    const r = sql.exec('SELECT id, u, b FROM t');
    out.columnNames = r.columnNames;
    out.rows = r.toArray().map((row) => Object.fromEntries(Object.entries(row).map(([k, v]) => [k, kind(v) + ' ' + (v instanceof ArrayBuffer ? [...new Uint8Array(v)] : v)])));
    out.raw = kind(sql.exec('SELECT id, u FROM t').raw());
    out.rawArray = Array.from(sql.exec('SELECT id, u FROM t').raw());
    for (const [name, q, args] of [
      ['pk', "INSERT INTO t (id, u, n) VALUES (1, 'z', 1)", []],
      ['unique', "INSERT INTO t (id, u, n) VALUES (2, 'a', 1)", []],
      ['notnull', "INSERT INTO t (id, u) VALUES (3, 'q')", []],
      ['check', "INSERT INTO t (id, u, n, c) VALUES (4, 'r', 1, -1)", []],
      ['fk', "INSERT INTO t (id, u, n, p) VALUES (5, 's', 1, 77)", []],
      ['datatype', "INSERT INTO s (id, v) VALUES (1, 'text')", []],
      ['trigger', "INSERT INTO t (id, u, n) VALUES (99, 'w', 1)", []],
      ['syntax', 'SELEC 1', []],
    ]) {
      try { sql.exec(q, ...args).toArray(); out[name] = 'no throw'; } catch (e) { out[name] = err(e) + ' | own: ' + Object.getOwnPropertyNames(e).join(','); }
    }
    for (const v of [2 ** 53 + 1, '9007199254740993', 2n ** 60n]) {
      try { out['bind ' + String(v) + ' ' + typeof v] = sql.exec('SELECT CAST(? AS INTEGER) AS x, typeof(?) AS t', v, v).toArray(); } catch (e) { out['bind ' + String(v) + ' ' + typeof v] = err(e); }
    }
    try { out.bigread = sql.exec('SELECT 9007199254740993 AS x').toArray(); } catch (e) { out.bigread = err(e); }
    try { out.bigreadText = sql.exec('SELECT CAST(9007199254740993 AS TEXT) AS x').toArray(); } catch (e) { out.bigreadText = err(e); }
    try { out.bigneg = sql.exec('SELECT -9223372036854775807 AS x').toArray(); } catch (e) { out.bigneg = err(e); }
    // The sync KV API
    const kv = this.ctx.storage.kv;
    kv.put('a1', new Uint8Array([1])); kv.put('a2', new Uint8Array([2])); kv.put('b1', new Uint8Array([3]));
    const g = kv.get('a1');
    out.kvGet = kind(g) + ' ' + [...new Uint8Array(g.buffer ?? g)];
    out.kvMissing = kind(kv.get('none'));
    const it = kv.list({ prefix: 'a' });
    out.kvList = kind(it);
    out.kvListItems = [...it].map(([k, v]) => k + ':' + kind(v));
    out.kvDelete = kv.delete('b1');
    out.kvDelete2 = kv.delete('b1');
    out.dbSize = typeof sql.databaseSize;
    out.id = this.ctx.id.toString();
    out.idName = this.ctx.id.name;
    try { await this.ctx.storage.setAlarm(Date.now() + 60000); out.setAlarmNoHandler = 'ok'; } catch (e) { out.setAlarmNoHandler = err(e); }
    return Response.json(out);
  }
}
export class Alarmed extends DurableObject {
  async fetch(req) {
    const u = new URL(req.url);
    if (u.pathname === '/runs') return Response.json(runs);
    if (u.pathname === '/old') {
      // deleteAll with an alarm set
      this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS x (a)');
      this.ctx.storage.kv.put('cell', 1);
      await this.ctx.storage.setAlarm(Date.now() + 600000);
      await this.ctx.storage.deleteAll();
      const tables = this.ctx.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'x'").toArray();
      return Response.json({ alarm: await this.ctx.storage.getAlarm(), cell: this.ctx.storage.kv.get('cell') ?? null, tables });
    }
    await this.ctx.storage.setAlarm(Date.now() + 50);
    return Response.json({ set: await this.ctx.storage.getAlarm() });
  }
  async alarm(info) {
    runs.push({ at: Date.now(), info: info === undefined ? 'undefined' : info });
    if ((info?.retryCount ?? 0) < 2) throw new Error('fail ' + (info?.retryCount ?? 0));
  }
}
export class KvBacked extends DurableObject {
  async fetch() {
    const out = {};
    try { out.size = this.ctx.storage.sql.databaseSize; } catch (e) { out.size = err(e); }
    try { this.ctx.storage.kv.put('a', 1); out.kv = 'ok'; } catch (e) { out.kv = err(e); }
    return Response.json(out);
  }
}
let inits = 0;
export class Init extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    inits++;
    ctx.blockConcurrencyWhile(async () => {
      await scheduler.wait(100);
      if (inits === 1) throw new Error('init failed once');
    });
  }
  async fetch() { return new Response('init ok ' + inits); }
  async hello(x) { return { got: x, kind: kind(x?.data), list: kind(x?.list) }; }
  async boom() { throw new Error('Nope(3)'); }
}
export class Admin extends WorkerEntrypoint {
  async fetch(req) { return new Response('admin fetch'); }
  async ping(x) { return 'admin ping ' + x; }
}
export default class extends WorkerEntrypoint {
  async fetch(req) {
    const env = this.env;
    const u = new URL(req.url);
    const out = {};
    if (u.pathname === '/sql') return env.SQL.getByName('one').fetch('http://o/');
    if (u.pathname === '/alarm') return env.ALARMED.getByName(u.searchParams.get('n')).fetch('http://o/');
    if (u.pathname === '/old') return env.ALARMED.getByName('old').fetch('http://o/old');
    if (u.pathname === '/runs') return env.ALARMED.getByName('x').fetch('http://o/runs');
    if (u.pathname === '/kvbacked') { try { return await env.KVB.getByName('k').fetch('http://o/'); } catch (e) { return new Response('throw ' + err(e)); } }
    if (u.pathname === '/init') { try { return await env.INIT.getByName('i').fetch('http://o/'); } catch (e) { return new Response('throw ' + err(e)); } }
    if (u.pathname === '/ids') {
      out.byName = env.SQL.idFromName('one').toString();
      try { out.jur = env.SQL.jurisdiction('eu').idFromName('one').toString(); } catch (e) { out.jur = err(e); }
      try { out.jurGet = kind(env.SQL.jurisdiction('eu').getByName('one')); } catch (e) { out.jurGet = err(e); }
      out.stubKind = kind(env.SQL.getByName('one'));
      out.stubId = env.SQL.getByName('one').id.toString();
      try { out.locHint = kind(env.SQL.getByName('one', { locationHint: 'weur' })); } catch (e) { out.locHint = err(e); }
      out.unique = env.SQL.newUniqueId().toString().length;
      return Response.json(out);
    }
    if (u.pathname === '/rpc') {
      const stub = env.INIT.getByName('r');
      out.hello = await stub.hello({ data: new Uint8Array([1, 2]), list: [1, 2] });
      try { await stub.boom(); } catch (e) { out.boom = err(e); }
      try { await stub.nothere(); } catch (e) { out.nothere = err(e); }
      out.adminPing = await env.ADMIN.ping(7);
      out.adminFetch = await (await env.ADMIN.fetch('http://a/')).text();
      out.selfPing = await env.SELF.sping(2);
      return Response.json(out);
    }
    return new Response('no');
  }
  async sping(x) { return 'self ' + x; }
}
`;
const self = Symbol.for('miniflare.kCurrentWorker');
const opts = (date) => ({
  modules: true, script, compatibilityDate: date,
  durableObjects: { SQL: { className: 'Sql', useSQLite: true }, ALARMED: { className: 'Alarmed', useSQLite: true }, KVB: { className: 'KvBacked', useSQLite: false }, INIT: { className: 'Init', useSQLite: true } },
  serviceBindings: { ADMIN: { name: self, entrypoint: 'Admin' }, SELF: self },
});
const mf = new Miniflare(convertV4MiniflareOptions(opts('2026-10-01')));
const get = async (p) => (await mf.dispatchFetch('http://x' + p)).text();
const show = (name, text) => { let v; try { v = JSON.stringify(JSON.parse(text), null, 1); } catch { v = text; } console.log(`== ${name}\n${v}`); };
show('sql', await get('/sql'));
show('ids', await get('/ids'));
show('kvbacked', await get('/kvbacked'));
show('init 1', await get('/init'));
show('init 2', await get('/init'));
show('rpc', await get('/rpc'));
const t0 = Date.now();
show('alarm set', await get('/alarm?n=x'));
let last = 0;
for (let i = 0; i < 40; i++) {
  await new Promise((r) => setTimeout(r, 1000));
  const runs = JSON.parse(await get('/runs'));
  if (runs.length !== last) { last = runs.length; console.log(`alarm runs at ${Date.now() - t0} ms: ${JSON.stringify(runs.map((r) => ({ t: r.at - t0, info: r.info })))}`); }
  if (runs.length >= 3 && Date.now() - t0 > 20000) break;
}
await mf.dispose();
const old = new Miniflare(convertV4MiniflareOptions(opts('2025-06-01')));
show('deleteAll, date 2025-06-01', await (await old.dispatchFetch('http://x/old')).text());
await old.dispose();
const neu = new Miniflare(convertV4MiniflareOptions(opts('2026-10-01')));
show('deleteAll, date 2026-10-01', await (await neu.dispatchFetch('http://x/old')).text());
await neu.dispose();
