// The isolate part of the test helper (research/design-notes/test-helper.md 5.2). `js/test.mjs` (Node) makes the entry file
// of a test in memory, and that file calls `testEntry`. A deploy never takes this file: Wrangler bundles only the
// modules that `main` imports.
//   const t = testEntry({ token, now, count, hooks, wrapEnv });
//   export default t.wrap(makeHandler(app, { ...options, now: t.now, wrapEnv: t.wrapEnv }));
// `t.now`: the clock of the shim (TH5). `t.wrapEnv`: the count of the bindings in `count` (TH6, TH16), then `wrapEnv` of the
// options file, then `hooks.wrapEnv` (TH7). `t.wrap(Handler)`: a subclass whose `fetch` answers the control path
// `/__cfw_test/<token>/...` and strips the header `cfw-test-request` before the app sees it (probe P1: the copy keeps
// `request.signal`).

export const TEST_ENTRY = 1;
export const REQUEST_HEADER = 'cfw-test-request';
export const CALLS_HEADER = 'cfw-test-calls';

// TH6: the methods that are one round trip to the binding, for each kind. `prepare`, `bind`, `withSession` are not calls.
const D1_STMT = new Set(['all', 'run', 'first', 'raw']);
const D1_DB = new Set(['batch', 'exec']);
const KV = new Set(['get', 'getWithMetadata', 'put', 'delete', 'list']);
const R2 = new Set(['get', 'head', 'put', 'delete', 'list', 'createMultipartUpload', 'resumeMultipartUpload']);
const QUEUE = new Set(['send', 'sendBatch']);

// The kind of a binding by its functions (the same tests as js/bindings.js).
export function kindOf(b) {
  const has = (...m) => b !== null && typeof b === 'object' && m.every((k) => typeof b[k] === 'function');
  if (has('prepare', 'batch')) return 'd1';
  if (has('head', 'put', 'createMultipartUpload')) return 'r2';
  if (has('get', 'put', 'getWithMetadata')) return 'kv';
  if (has('send', 'sendBatch')) return 'queue';
  return null;
}

// A proxy of `target` whose functions are bound to it, and `pick(name, fn)` for the methods that it replaces. `rawOf`: the
// target of a proxy, so a D1 `batch` gets the real statements (the binding may check their class).
const targets = new WeakMap();
const rawOf = (v) => targets.get(v) ?? v;
const proxy = (target, pick) => {
  const p = new Proxy(target, {
    get(t, k) {
      const v = Reflect.get(t, k);
      if (typeof v !== 'function') return v;
      return pick(k, v.bind(t)) ?? v.bind(t);
    },
  });
  targets.set(p, target);
  return p;
};

// The counted form of one binding. `rec(op, session)`: one call. `onSession(arg)`: a `withSession` argument.
export function countBinding(b, rec, onSession) {
  const kind = kindOf(b);
  const methods = (set, session) => (k, f) => (set.has(k) ? (...a) => (rec(k, session), f(...a)) : null);
  if (kind === 'd1') {
    const stmt = (s, session) =>
      proxy(s, (k, f) => {
        if (k === 'bind') return (...a) => stmt(f(...a), session);
        return methods(D1_STMT, session)(k, f);
      });
    const db = (d, session) =>
      proxy(d, (k, f) => {
        if (k === 'prepare') return (...a) => stmt(f(...a), session);
        if (k === 'withSession') return (...a) => {
          const arg = a[0] === undefined ? null : String(a[0]);
          onSession(arg);
          return db(f(...a), arg);
        };
        if (k === 'batch') return (stmts, ...a) => (rec(k, session), f(Array.isArray(stmts) ? stmts.map(rawOf) : stmts, ...a));
        return methods(D1_DB, session)(k, f);
      });
    return db(b, null);
  }
  const set = kind === 'kv' ? KV : kind === 'r2' ? R2 : kind === 'queue' ? QUEUE : null;
  if (!set) return b;
  return proxy(b, methods(set, null));
}

// opts: `token` (the control path), `now` (ms or null: the real clock), `count` (binding names), `hooks` (a module
// namespace: `wrapEnv`, `fetch`), `wrapEnv` (of the options file of the app), `caches` (false: no record of the cache keys).
export function testEntry(opts = {}) {
  const { token, count = [], hooks = {} } = opts;
  if (typeof token !== 'string' || !token) throw new TypeError('testEntry: token must be a text');
  const start = opts.now ?? null;
  let fixed = start;
  const now = () => fixed ?? Date.now();
  const counted = new Set(count);
  // Each call: { binding, op, session, request, kind, name } (`request`: the number of the request, or null).
  let calls = [];
  // The request of each Fetch event: the copy of the request (without the header) to its number. `open`: the requests whose
  // response is not sent yet (TH4: the calls after the response go to `app.calls()` only).
  const reqOf = new WeakMap();
  const open = new Map();

  const appWrap = opts.wrapEnv;
  const wrapEnv = (env, info) => {
    let out = env;
    if (counted.size && env && typeof env === 'object') {
      const n = info.kind === 'Fetch' && info.event && reqOf.has(info.event) ? reqOf.get(info.event) : null;
      out = { ...env };
      for (const name of counted) {
        if (env[name] === undefined || env[name] === null) continue;
        out[name] = countBinding(
          env[name],
          (op, session) => {
            const c = { binding: name, op, session, request: n, kind: info.kind, name: info.name };
            calls.push(c);
            if (n !== null && open.has(n)) open.get(n).calls.push(c);
          },
          (arg) => {
            if (n !== null && open.has(n)) (open.get(n).sessions[name] ??= []).push(arg);
          },
        );
      }
    }
    if (appWrap) out = appWrap(out, info);
    if (typeof hooks.wrapEnv === 'function') out = hooks.wrapEnv(out, info);
    return out;
  };

  // P2: the Cache API keys that the app put (`caches.default`, `caches.open(name)`), for `reset`.
  const cacheKeys = new Map(); // `${name}\n${url}` -> [name, url]
  const realCaches = globalThis.caches;
  if (opts.caches !== false && realCaches && typeof realCaches.open === 'function') {
    const wrapCache = (c, name) =>
      proxy(c, (k, f) => {
        if (k !== 'put') return null;
        return (req, res) => {
          const url = typeof req === 'string' ? req : req.url;
          cacheKeys.set(`${name}\n${url}`, [name, url]);
          return f(req, res);
        };
      });
    const named = new Map();
    const wrapped = {
      default: wrapCache(realCaches.default, null),
      open: async (name) => {
        const c = await realCaches.open(name);
        if (!named.has(name)) named.set(name, wrapCache(c, name));
        return named.get(name);
      },
      has: (...a) => realCaches.has?.(...a),
      delete: (...a) => realCaches.delete?.(...a),
      keys: (...a) => realCaches.keys?.(...a),
      match: (...a) => realCaches.match?.(...a),
    };
    globalThis.caches = wrapped;
  }
  const clearCaches = async () => {
    let n = 0;
    for (const [name, url] of cacheKeys.values()) {
      const c = name === null ? realCaches.default : await realCaches.open(name);
      if (await c.delete(url)) n++;
    }
    cacheKeys.clear();
    return n;
  };

  let Handler = null;
  const runner = () => Handler.runner;
  const json = (v, status = 200) => new Response(JSON.stringify(v), { status, headers: { 'content-type': 'application/json' } });
  const prefix = `/__cfw_test/${token}/`;
  async function control(path, url) {
    const q = url.searchParams;
    if (path === 'now') {
      if (q.has('ms')) {
        const v = q.get('ms');
        fixed = v === '' || v === 'null' ? null : Number(v);
        if (fixed !== null && !Number.isFinite(fixed)) return json({ error: `now: bad ms ${v}` }, 400);
      }
      return json({ now: fixed });
    }
    if (path === 'calls') {
      const out = calls;
      if (q.get('reset') === '1') calls = [];
      return json({ calls: out });
    }
    if (path === 'tasks') return json({ tasks: runner().tasks.size, pins: runner().pins.size });
    // TH15: the clock, the pins (probe P3), the cache keys (probe P2), the calls. D1, KV, R2: the helper in Node.
    if (path === 'reset') {
      const tasks = runner().tasks.size;
      if (tasks) return json({ error: `reset: ${tasks} tasks run` }, 409);
      fixed = start;
      runner().pins.clear();
      calls = [];
      return json({ caches: await clearCaches() });
    }
    return json({ error: `no control path ${path}` }, 404);
  }

  function wrap(H) {
    Handler = H;
    return class extends H {
      async fetch(request) {
        const url = new URL(request.url);
        if (url.pathname.startsWith(prefix)) return control(url.pathname.slice(prefix.length), url);
        const id = request.headers.get(REQUEST_HEADER);
        if (id === null) return this.#app(request);
        // O1, probe P1: a copy with no header keeps `request.signal`.
        const headers = new Headers(request.headers);
        headers.delete(REQUEST_HEADER);
        const copy = new Request(request, { headers });
        const n = Number(id);
        reqOf.set(copy, n);
        const rec = { calls: [], sessions: {} };
        open.set(n, rec);
        let res;
        try {
          res = await this.#app(copy);
        } finally {
          open.delete(n);
        }
        if (res.status === 101 || res.webSocket) return res;
        const out = new Response(res.body, res);
        out.headers.set(CALLS_HEADER, encodeURIComponent(JSON.stringify(rec)));
        return out;
      }
      // TH7: `hooks.fetch(request, env, next)` before the app. Its `env` is the counted one of this request.
      #app(request) {
        if (typeof hooks.fetch !== 'function') return super.fetch(request);
        const env = wrapEnv(this.env, { kind: 'Fetch', name: 'hooks.fetch', event: request });
        return hooks.fetch(request, env, (r = request) => super.fetch(r));
      }
    };
  }

  return { now, wrapEnv, wrap };
}
