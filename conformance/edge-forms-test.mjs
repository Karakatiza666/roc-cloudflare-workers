// node conformance/edge-forms-test.mjs
// PLAN.md 11c, EP7: some checks of `checks/*.mjs` have a local form and an edge form of an answer (`t.edge`). This test runs
// them with a fake `t` whose answers are the ones that the edge gave (edge/results/conformance-2.txt, PLAN.md E15, E17, E18,
// E23, E39, E42, E43). Each check must pass with `edge: true` and the edge answers, and must FAIL with `edge: false` and the same
// answers: the local form stays strict. Exit 1 on a miss. No Miniflare and no network.
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const all = new Map();
for (const f of readdirSync(join(here, 'checks')).filter((x) => x.endsWith('.mjs'))) {
  for (const [name, fn] of (await import(pathToFileURL(join(here, 'checks', f)))).checks ?? []) all.set(name, fn);
}

const HEX64 = 'a'.repeat(64);
const q = encodeURIComponent;
const text = (body, extra = {}) => ({ status: 200, body, waits: 0, awaits: 0, calls: 0, ms: 0, ...extra });
// The answers of the edge, by path. A function gets the number of the call of that path (from 1).
const edgeAnswers = {
  [`/http/get?url=${q('http://127.0.0.1:1/')}`]: () => text('403 error code: 1003'),
  [`/http/get?url=${q('http://no-such-host.invalid/')}`]: () => text('530 error code: 1016'),
  '/assets/fetch?path=/hello.txt': () => text('status=200 type=text/plain body=hello-asset\n', { awaits: 2 }),
  '/assets/pass?path=/hello.txt': () => text('hello-asset\n', { awaits: 1 }),
  '/assets/pass_io?path=/hello.txt': () => text('hello-asset\n'),
  '/assets/fetch_io?path=/hello.txt': () => text('status=200 type=text/plain body=hello-asset\n'),
  '/assets/fetch?path=/index.html': () => text('status=200 type=text/html body=<h1>index</h1>\n'),
  // The third call is Ok too: the limit is per location and not exact.
  '/ratelimit/limit?key=a': () => text('Ok'),
  '/ratelimit/limit?key=b': () => text('Ok'),
  '/ratelimit/limit_io?key=c': () => text('Ok'),
  '/objects/jurisdiction?name=x': () => text(`Ok("${'b'.repeat(64)}")`),
  '/objects/id?name=x': () => text(`outside=Ok("${HEX64}") same=True`),
  '/queue/batch?count=101': () => text('Err QueueErr({ message: "batch message count of 101 exceeds limit of 100 (10206)", name: "Error" })'),
  '/workflows/create?binding=FLOW&pname=x&n=3': () => text(`Ok id=cf_${HEX64}`, { awaits: 1 }),
  '/workflows/create_io?binding=FLOW&pname=x&n=3': () => text(`Ok id=cf_${HEX64}`, { awaits: 1 }),
  '/workflows/create_with_none?binding=FLOW&pname=x&n=1': () => text(`Ok id=cf_${HEX64}`),
};
const checks = [
  'http 8d: a closed port is Network',
  'http 8d: a host that does not exist is Network',
  'assets fetch!: a file, one wait (the body of the answer is read in a second one)',
  'assets fetch (Io twin)',
  'assets fetch!: the url of the request',
  'assets fetch!: pass the response as it is (a stream), also the Io twin',
  'ratelimit limit!',
  'ratelimit limit (Io twin)',
  'objects jurisdiction(Eu): id! gives ObjectErr in Miniflare, a different id on the edge',
  'queue send_batch! of 101 messages is QueueErr',
  'workflows create!, create (Io twin): an instance with a new id, and its output has the parameters',
];

function fakeT(edge) {
  const calls = {};
  const lookup = (path) => {
    const key = Object.keys(edgeAnswers).find((k) => path === k || path.startsWith(`${k}&label=`));
    if (!key) throw new Error(`the fake edge has no answer for ${path}`);
    calls[key] = (calls[key] ?? 0) + 1;
    return edgeAnswers[key](calls[key]);
  };
  return {
    edge,
    server: 'http://server',
    async get(path) {
      // The status of a workflow instance: complete, with the output of the id that the check made.
      const m = /^\/workflows\/status\?binding=FLOW&id=(.+)$/.exec(path);
      if (m) return text(`state=Complete error=Err(NotSet) json=Ok("{}") done payload=x/3 id=${m[1]}`);
      return lookup(path);
    },
    mf: {
      dispatchFetch: async (url) => {
        const u = new URL(url);
        const r = lookup(u.pathname + u.search);
        return new Response(r.body, { status: r.status, headers: { 'content-type': 'text/plain' } });
      },
    },
  };
}

const run = async (name, edge) => {
  try {
    await all.get(name)(fakeT(edge));
    return null;
  } catch (e) {
    return e.message;
  }
};

let bad = 0;
for (const name of checks) {
  if (!all.has(name)) {
    console.log(`MISSING check: ${name}`);
    bad++;
    continue;
  }
  const onEdge = await run(name, true);
  const local = await run(name, false);
  const good = onEdge === null && local !== null;
  console.log(`${good ? 'PASS' : 'FAIL'} ${name}${good ? '' : `: ${onEdge === null ? 'the local form accepts the edge answer' : `the edge form fails: ${onEdge.slice(0, 200)}`}`}`);
  if (!good) bad++;
}
console.log(bad ? 'FAIL' : 'PASS');
process.exit(bad ? 1 : 0);
