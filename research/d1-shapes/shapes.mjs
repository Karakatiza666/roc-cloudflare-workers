// The shapes that local D1 gives (PLAN.md 8c, D1 wave): meta, all(), raw(), first() of no row, batch(),
// withSession and getBookmark, and a blob. The design of the programs of platform/D1.roc.
//   node research/d1-shapes/shapes.mjs   (Miniflare of the global wrangler)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
const show = (v) => JSON.parse(JSON.stringify(v, (k, x) => x instanceof ArrayBuffer ? { ArrayBuffer: [...new Uint8Array(x)] } : typeof x === 'bigint' ? 'bigint ' + x : x));
const kind = (v) => v === null ? 'null' : Array.isArray(v) ? 'Array' : v instanceof ArrayBuffer ? 'ArrayBuffer' : typeof v === 'object' ? (Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto') : typeof v;
export default { async fetch(req, env) {
  const db = env.DB;
  const out = {};
  out.exec = show(await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT, b BLOB, r REAL)"));
  const run = await db.prepare("INSERT INTO t (id, v, b, r) VALUES (?, ?, ?, ?)").bind(5, 'a', new Uint8Array([1, 2, 3]), 1.5).run();
  out.run = show(run); out.runKinds = Object.fromEntries(Object.entries(run.meta).map(([k, v]) => [k, kind(v)]));
  const all = await db.prepare("SELECT * FROM t").all();
  out.all = show(all); out.allBlob = kind(all.results[0].b);
  out.raw = show(await db.prepare("SELECT * FROM t").raw({ columnNames: true }));
  out.rawBlob = kind((await db.prepare("SELECT * FROM t").raw())[0][2]);
  out.rawEmpty = show(await db.prepare("SELECT * FROM t WHERE id = 99").raw({ columnNames: true }));
  out.firstNone = show(await db.prepare("SELECT * FROM t WHERE id = 99").first());
  const b = await db.batch([db.prepare("INSERT INTO t (id, v) VALUES (6, 'b')"), db.prepare("SELECT count(*) AS n FROM t")]);
  out.batch = show(b); out.batchKinds = b.map((x) => kind(x));
  const s = db.withSession("first-primary");
  out.session = kind(s); out.bookmark0 = s.getBookmark();
  await s.prepare("INSERT INTO t (id, v) VALUES (7, 'c')").run();
  out.bookmark1 = s.getBookmark();
  try { db.withSession("bad bookmark"); out.badSession = 'no throw'; } catch (e) { out.badSession = e.name + ': ' + e.message; }
  try { await db.withSession("bad bookmark").prepare("SELECT 1").all(); out.badSessionQuery = 'no throw'; } catch (e) { out.badSessionQuery = e.name + ': ' + e.message; }
  try { await db.prepare("SELECT ?").bind(2n ** 60n).all(); } catch (e) { out.bigint = e.name + ': ' + e.message; }
  try { await db.exec("SELEC 1"); } catch (e) { out.execErr = e.name + ': ' + e.message; }
  return Response.json(out);
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', d1Databases: ['DB'] }));
console.log(JSON.stringify(JSON.parse(await (await mf.dispatchFetch('http://x/')).text()), null, 1));
await mf.dispose();
