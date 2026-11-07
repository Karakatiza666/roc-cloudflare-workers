// A confidence interval for the CPU difference of two Worker versions in one window. The analytics give no per-request
// CPU, so the unit is one second: per version and second, the requests and the CPU sum (workersInvocationsAdaptive,
// dimensions scriptVersion and datetime). Statistic: mean CPU of B / mean CPU of A - 1 (sums over the seconds).
// 95 % interval: bootstrap over the seconds (a resampled second keeps both versions: paired, the same load).
//   node edgeci.mjs --from <ISO> --to <ISO> --a <version id> --b <version id> [--script talon-registry-bench] [--n 10000]
// Env: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN (never printed).
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i += 2) opt[argv[i].slice(2)] = argv[i + 1];
const query = `query($acc: String!, $script: String!, $from: Time!, $to: Time!) {
  viewer { accounts(filter: { accountTag: $acc }) {
    workersInvocationsAdaptive(limit: 10000, filter: { scriptName: $script, datetime_geq: $from, datetime_leq: $to }) {
      dimensions { scriptVersion datetime }
      sum { requests cpuTimeUs }
      quantiles { cpuTimeP50 }
    }
  } }
}`;
const r = await fetch('https://api.cloudflare.com/client/v4/graphql', {
  method: 'POST',
  headers: { authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}`, 'content-type': 'application/json' },
  body: JSON.stringify({ query, variables: { acc: process.env.CLOUDFLARE_ACCOUNT_ID, script: opt.script ?? 'talon-registry-bench', from: opt.from, to: opt.to } }),
});
const j = await r.json();
if (j.errors?.length) throw new Error(JSON.stringify(j.errors));
const groups = j.data.viewer.accounts[0].workersInvocationsAdaptive;
const sec = new Map();
for (const g of groups) {
  const k = g.dimensions.datetime;
  const v = g.dimensions.scriptVersion === opt.a ? 'a' : g.dimensions.scriptVersion === opt.b ? 'b' : null;
  if (!v) continue;
  const s = sec.get(k) ?? { a: [0, 0, 0], b: [0, 0, 0] };
  s[v][0] += g.sum.requests;
  s[v][1] += g.sum.cpuTimeUs;
  s[v][2] = g.quantiles.cpuTimeP50;
  sec.set(k, s);
}
const S = [...sec.values()];
const stat = (xs) => {
  let ra = 0, ca = 0, rb = 0, cb = 0;
  for (const s of xs) { ra += s.a[0]; ca += s.a[1]; rb += s.b[0]; cb += s.b[1]; }
  return { ma: ca / ra, mb: cb / rb, ra, rb, d: cb / rb / (ca / ra) - 1 };
};
const all = stat(S);
const n = Number(opt.n ?? 10000);
let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const ds = [];
for (let i = 0; i < n; i++) ds.push(stat(Array.from({ length: S.length }, () => S[Math.floor(rnd() * S.length)])).d);
ds.sort((x, y) => x - y);
const pc = (x) => `${(x * 100).toFixed(1)} %`;
// Second statistic, robust to the cold starts (an isolate compiles its wasm at its first requests, 30 to 70 ms): the
// median over the seconds that have both versions of log(p50 of b / p50 of a), the same bootstrap.
const P = S.filter((s) => s.a[0] > 0 && s.b[0] > 0 && s.a[2] > 0 && s.b[2] > 0).map((s) => Math.log(s.b[2] / s.a[2]));
const medOf = (xs) => { const b = [...xs].sort((x, y) => x - y); return b[Math.floor(b.length / 2)]; };
const pm = [];
for (let i = 0; i < n; i++) pm.push(medOf(Array.from({ length: P.length }, () => P[Math.floor(rnd() * P.length)])));
pm.sort((x, y) => x - y);
const ex = (x) => Math.exp(x) - 1;
console.log(`p50 per second (${P.length} seconds with both): median b/a - 1 = ${pc(ex(medOf(P)))}, 95 % CI ${pc(ex(pm[Math.floor(0.025 * n)]))} to ${pc(ex(pm[Math.floor(0.975 * n)]))}`);
console.log(`seconds ${S.length}, requests a ${all.ra} b ${all.rb}; mean CPU a ${all.ma.toFixed(0)} µs, b ${all.mb.toFixed(0)} µs; b/a - 1 = ${pc(all.d)}, 95 % CI ${pc(ds[Math.floor(0.025 * n)])} to ${pc(ds[Math.floor(0.975 * n)])}`);
