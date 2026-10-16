// last_row_id of D1 meta after an insert of a 64-bit rowid
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
const mfDir = join(dirname(dirname(process.execPath)), 'lib/node_modules/wrangler/node_modules/miniflare');
const { Miniflare, convertV4MiniflareOptions } = createRequire(import.meta.url)(mfDir);
const script = `export default { async fetch(req, env) {
  const db = env.DB;
  await db.exec("CREATE TABLE names (id INTEGER PRIMARY KEY, v TEXT)");
  const r = await db.prepare("INSERT INTO names (id, v) VALUES (?, 'a')").bind("-2687166099708853831").run();
  const b = await db.batch([db.prepare("INSERT INTO names (id, v) VALUES (?, 'b')").bind("9223372036854775807")]);
  return Response.json({ run: r.meta, batch: b[0].meta, types: [typeof r.meta.last_row_id, Number.isSafeInteger(r.meta.last_row_id)] });
} };`;
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script, compatibilityDate: '2026-10-01', d1Databases: ['DB'] }));
console.log(await (await mf.dispatchFetch('http://x/')).text());
await mf.dispose();
