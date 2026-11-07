// CPU time per Worker version from the Workers analytics (GraphQL workersInvocationsAdaptive), for the A/B runs
// of research/alloc/foreign/README.md on the bench Worker. Env: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN.
//   node edgecpu.mjs --from <ISO time> --to <ISO time> [--script talon-registry-bench] [--json out.json] [--d1 <database id>]
// --d1: also the D1 rows read and written in the window (the free plan: 5 M rows read a day for the account).
// Prints per version: requests, errors, CPU time quantiles (µs), wall time p50, and the mean CPU (sum / requests).
import { writeFileSync } from 'node:fs';

const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i += 2) opt[argv[i].slice(2)] = argv[i + 1];
const acc = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
if (!acc || !token) throw new Error('set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN');
const query = `query($acc: String!, $script: String!, $from: Time!, $to: Time!) {
  viewer { accounts(filter: { accountTag: $acc }) {
    workersInvocationsAdaptive(limit: 1000, filter: { scriptName: $script, datetime_geq: $from, datetime_leq: $to }) {
      dimensions { scriptVersion }
      sum { requests errors cpuTimeUs wallTime }
      quantiles { cpuTimeP25 cpuTimeP50 cpuTimeP75 cpuTimeP90 cpuTimeP99 wallTimeP50 }
    }
  } }
}`;
const r = await fetch('https://api.cloudflare.com/client/v4/graphql', {
  method: 'POST',
  headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
  body: JSON.stringify({ query, variables: { acc, script: opt.script ?? 'talon-registry-bench', from: opt.from, to: opt.to } }),
});
const j = await r.json();
if (j.errors?.length) {
  console.error(JSON.stringify(j.errors, null, 1));
  process.exit(1);
}
const rows = j.data.viewer.accounts[0].workersInvocationsAdaptive.map((x) => ({
  version: x.dimensions.scriptVersion,
  requests: x.sum.requests,
  errors: x.sum.errors,
  cpuMeanUs: +(x.sum.cpuTimeUs / x.sum.requests).toFixed(0),
  ...x.quantiles,
}));
console.table(rows);
if (opt.json) writeFileSync(opt.json, JSON.stringify(rows, null, 1));

if (opt.d1) {
  const q2 = `query($acc: String!, $db: String!, $from: Time!, $to: Time!) {
    viewer { accounts(filter: { accountTag: $acc }) {
      d1AnalyticsAdaptiveGroups(limit: 10, filter: { databaseId: $db, datetime_geq: $from, datetime_leq: $to }) { sum { readQueries writeQueries rowsRead rowsWritten } }
    } } }`;
  const r2 = await fetch('https://api.cloudflare.com/client/v4/graphql', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ query: q2, variables: { acc, db: opt.d1, from: opt.from, to: opt.to } }),
  });
  const j2 = await r2.json();
  if (j2.errors?.length) console.error(JSON.stringify(j2.errors, null, 1));
  else console.log('D1', JSON.stringify(j2.data.viewer.accounts[0].d1AnalyticsAdaptiveGroups.map((x) => x.sum)));
}
