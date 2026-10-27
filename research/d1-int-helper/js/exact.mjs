// J-probe: can the JS side of local D1 give an exact 64-bit integer? Each D1 call, each SQL text trick, and the
// internal `fetcher` of the binding (raw response text).
//   node research/d1-int-helper/js/exact.mjs   (Miniflare of the global wrangler)
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `
const show = (v) => JSON.parse(JSON.stringify(v, (k, x) => typeof x === 'bigint' ? 'bigint ' + x : typeof x === 'number' ? (Number.isSafeInteger(x) || !Number.isInteger(x) ? x : 'UNSAFE ' + x) : x));
export default { async fetch(req, env) {
  const db = env.DB;
  const out = {};
  await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)");
  const big = '9007199254740993'; // 2^53 + 1
  const ins = await db.prepare("INSERT INTO t (id, n) VALUES (?, ?)").bind(big, '-9007199254740993').run();
  out.meta_last_row_id = show(ins.meta.last_row_id);
  out.all = show((await db.prepare("SELECT id, n FROM t").all()).results);
  out.raw = show(await db.prepare("SELECT id, n FROM t").raw());
  out.first = show(await db.prepare("SELECT id, n FROM t").first());
  out.first_col = show(await db.prepare("SELECT id, n FROM t").first('id'));
  out.typeof = show(await db.prepare("SELECT typeof(id) AS a, typeof(n) AS b FROM t").first());
  out.cast_text = show(await db.prepare("SELECT CAST(id AS TEXT) AS id, CAST(n AS TEXT) AS n FROM t").first());
  out.printf = show(await db.prepare("SELECT printf('%d', id) AS id FROM t").first());
  out.concat = show(await db.prepare("SELECT id || '' AS id FROM t").first());
  out.json_object = show(await db.prepare("SELECT json_object('id', id) AS j FROM t").first());
  out.returning = show(await db.prepare("INSERT INTO t (id, n) VALUES (?, 1) RETURNING CAST(id AS TEXT) AS id").bind('9007199254740995').first());
  out.compare_text_param = show(await db.prepare("SELECT count(*) AS c FROM t WHERE id = ?").bind(big).first());
  out.add_in_sql = show(await db.prepare("SELECT CAST(id + 1 AS TEXT) AS id FROM t WHERE id = ?").bind(big).first());
  // the CAST of a column that holds a REAL (no affinity): the text of the float, not an integer
  await db.exec("CREATE TABLE u (v)");
  await db.prepare("INSERT INTO u (v) VALUES (?)").bind(5).run();
  out.cast_real_no_affinity = show(await db.prepare("SELECT typeof(v) AS t, CAST(v AS TEXT) AS v FROM u").first());
  // internal: the fetcher of the binding, raw text of the upstream answer
  out.has_fetcher = typeof db.fetcher;
  try {
    const r = await db.fetcher.fetch('http://d1/query?resultsFormat=ROWS_AND_COLUMNS', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ sql: 'SELECT id FROM t', params: [] }) });
    out.fetcher_text = await r.text();
  } catch (e) { out.fetcher_text = 'throw ' + e.message; }
  out.has_query_rpc = typeof db.fetcher?.query;
  return Response.json(out);
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', d1Databases: ['DB'] }));
console.log(JSON.stringify(JSON.parse(await (await mf.dispatchFetch('http://x/')).text()), null, 1));
await mf.dispose();
