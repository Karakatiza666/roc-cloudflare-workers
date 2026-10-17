// PLAN.md step 8g: the shared part of the measure harnesses (`run-node.mjs`, `run-mf.mjs`, `run-edge.mjs`).
// A case is a route of `app.roc` that runs one operation `n` times in one request. The cost of one operation is
// (time of a request with n = N, less time of a request with n = 0) / N, paired, `rounds` times. N comes from a probe:
// the request must take about `targetMs`, so the clock and the HTTP path do not matter. Gives median, min and max.

export const median = (xs) => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];
export const round = (x, d = 1) => Math.round(x * 10 ** d) / 10 ** d;

// get(pathWithQuery) gives a Response. now(): a clock in ms.
export function makeMeasure(get, { now = () => performance.now(), rounds = 9, targetMs = 100, warm = true } = {}) {
  const run = async (path, n) => {
    const url = `${path}${path.includes('?') ? '&' : '?'}n=${n}`;
    const t0 = now();
    const res = await get(url);
    const body = await res.text();
    const ms = now() - t0;
    if (res.status !== 200) throw new Error(`${url}: status ${res.status}: ${body.slice(0, 200)}`);
    return { ms, body };
  };
  // Probe: the base (n = 0, median of 3), then n grows by 4 until a request takes 20 ms more than the base. N is sized for `targetMs`.
  const size = async (path, target = targetMs) => {
    const bases = [];
    for (let i = 0; i < 3; i++) bases.push((await run(path, 0)).ms);
    const base = median(bases);
    let n = 2;
    let r = await run(path, n);
    while (r.ms - base < 20 && n < 4_000_000) {
      n *= 4;
      r = await run(path, n);
    }
    const per = Math.max((r.ms - base) / n, 1e-6);
    return Math.max(2, Math.ceil(target / per));
  };
  // One case: microseconds per operation.
  const measure = async (path, opts = {}) => {
    const N = opts.n ?? (await size(path, opts.targetMs));
    if (warm) await run(path, Math.max(1, Math.floor(N / 4)));
    const est = [];
    let body = '';
    for (let i = 0; i < (opts.rounds ?? rounds); i++) {
      const b = await run(path, 0);
      const t = await run(path, N);
      body = t.body;
      est.push(((t.ms - b.ms) / N) * 1000);
    }
    return { path, N, us: round(median(est), 3), min: round(Math.min(...est), 3), max: round(Math.max(...est), 3), body };
  };
  return { run, measure };
}

// The cases of the plan. `rows`: the D1 row counts. `sizes`: the SHA-256 buffer sizes in bytes.
export const ROWS = [20, 200];
export const SIZES = [256, 1024, 2048, 4096, 8192, 16384, 65536, 262144, 1048576];

export const crossCases = () => {
  const out = [];
  for (const how of ['call', 'await', 'build']) for (const k of [0, 1, 4, 16]) out.push({ group: 'cross', name: `${how} k=${k}`, path: `/cross/${how}?k=${k}` });
  return out;
};
export const d1Cases = (fake = false) => {
  const out = [];
  for (const rows of ROWS) for (const name of ['js_only', 'pack_only', 'all', 'all_arrays', 'raw_js_only', 'raw_only', 'obj_tree', 'tree_typed', 'rows']) out.push({ group: 'd1', name: `${name} rows=${rows}${fake ? ' fake' : ''}`, path: `/d1/${name}?rows=${rows}${fake ? '&fake=1' : ''}` });
  return out;
};
export const parseCases = () => {
  const out = [];
  for (const rows of ROWS) for (const name of ['records', 'tuples', 'variant_field', 'variant_first', 'fold_only']) out.push({ group: 'parse', name: `${name} rows=${rows}`, path: `/parse/${name}?rows=${rows}&fake=1` });
  return out;
};
export const shaCases = (sizes = SIZES) => {
  const out = [];
  for (const size of sizes) for (const name of ['wasm', 'digest', 'digest_js', 'copy_only']) out.push({ group: 'sha', name: `${name} size=${size}`, path: `/sha/${name}?size=${size}` });
  return out;
};

// The answers that must agree (the checks that the cases measure the same work): the sums of the three parse routes, and
// the digests of the two SHA-256 routes with the same bytes.
export async function sanity({ run }) {
  const fails = [];
  for (const rows of ROWS) {
    const sums = [];
    for (const name of ['records', 'tuples', 'variant_field', 'variant_first']) sums.push((await run(`/parse/${name}?rows=${rows}&fake=1`, 5)).body.split(' ')[3]);
    if (new Set(sums).size !== 1 || !(Number(sums[0]) > 0)) fails.push(`parse rows=${rows}: the sums differ: ${sums.join(' ')}`);
  }
  for (const size of [1, 1024, 70000]) {
    const a = (await run(`/sha/wasm?size=${size}`, 3)).body.split(' ')[3];
    const b = (await run(`/sha/digest?size=${size}`, 3)).body.split(' ')[3];
    if (a !== b || a.length !== 64) fails.push(`sha size=${size}: wasm ${a} and digest ${b} differ`);
  }
  return fails;
}

export function table(results, cols) {
  const lines = [`| ${cols.map((c) => c[0]).join(' | ')} |`, `| ${cols.map(() => '---').join(' | ')} |`];
  for (const r of results) lines.push(`| ${cols.map((c) => c[1](r)).join(' | ')} |`);
  return lines.join('\n');
}

export const fmt = (r) => `${r.us} (${r.min} to ${r.max})`;
