// The "other bindings" of the conformance worker (PLAN.md 8f, part 4): JS stubs for the bindings that Miniflare has no
// local form of (Workers AI and Vectorize are remote only), and for the value that a test must see (the data point
// of Analytics Engine, the version metadata). A stub is a plain object with the methods of the binding. It records each
// call, `GET /__stub_calls` gives the record, `POST /__stub_reset` clears it and the stores. `withStubs(env)` puts the
// stubs in the env of each request, so the Roc code reads `env[name]` as it does for a real binding. The two workflow
// classes (Flow, Waiter) are the targets of the local Workflows binding.
import { WorkflowEntrypoint } from 'cloudflare:workers';

let calls = [];
const rec = (binding, method, args) => {
  // The calls are the data that the test reads: a BigInt becomes text, a stream a marker.
  calls.push({ binding, method, args: JSON.parse(JSON.stringify(args, (k, v) => (typeof v === 'bigint' ? `${v}n` : v instanceof ReadableStream ? '<stream>' : v === undefined ? null : v))) });
};

const encoder = new TextEncoder();
const sseStream = (...events) => new ReadableStream({
  start(c) {
    for (const e of events) c.enqueue(encoder.encode(`data: ${e}\n\n`));
    c.close();
  },
});

// Workers AI: `run(model, input, options)`. `@test/throw` throws, `@test/big` gives 1.2 MB, a stream input gives server-sent events.
const AI = {
  run(model, input, options) {
    rec('AI', 'run', [model, input, options]);
    if (model === '@test/throw') throw new Error('no such model');
    if (model === '@test/big') return { response: 'x'.repeat(1_200_000) };
    if (input && input.stream === true) return sseStream('{"response":"a"}', '{"response":"b"}', '[DONE]');
    return { response: `echo ${model}: ${input?.prompt ?? ''}`, usage: { prompt_tokens: 3, completion_tokens: 2 } };
  },
};

// Vectorize v2: an in-memory index (the namespace `big` has one match with 1.2 MB of metadata). `query` gives the vectors by id, with the score 1 / (rank + 1); `filter` is an equality
// filter on the metadata; `returnValues` and `returnMetadata` decide the fields of a match.
let store = new Map();
const VECTORIZE = {
  query(vector, options = {}) {
    rec('VECTORIZE', 'query', [vector, options]);
    if (!Array.isArray(vector)) throw new TypeError('the query vector is not an array');
    if (options.namespace === 'big') return { matches: [{ id: 'big', score: 1, metadata: { genre: 'x'.repeat(1_200_000), year: 1 } }], count: 1 };
    let all = [...store.values()].sort((a, b) => (a.id < b.id ? -1 : 1));
    if (options.namespace !== undefined) all = all.filter((v) => v.namespace === options.namespace);
    if (options.filter) all = all.filter((v) => Object.entries(options.filter).every(([k, want]) => v.metadata?.[k] === want));
    const matches = all.slice(0, options.topK ?? 5).map((v, i) => {
      const m = { id: v.id, score: 1 / (i + 1) };
      if (options.returnValues) m.values = v.values;
      if (v.namespace !== undefined) m.namespace = v.namespace;
      if (v.metadata !== undefined && options.returnMetadata && options.returnMetadata !== 'none') m.metadata = v.metadata;
      return m;
    });
    return { matches, count: matches.length };
  },
  upsert(vectors) {
    rec('VECTORIZE', 'upsert', [vectors]);
    for (const v of vectors) store.set(v.id, v);
    return { mutationId: `up-${vectors.length}` };
  },
  insert(vectors) {
    rec('VECTORIZE', 'insert', [vectors]);
    for (const v of vectors) if (!store.has(v.id)) store.set(v.id, v);
    return { mutationId: `in-${vectors.length}` };
  },
  getByIds(ids) {
    rec('VECTORIZE', 'getByIds', [ids]);
    if (ids.includes('big')) return [{ id: 'big', values: [], metadata: { genre: 'x'.repeat(1_200_000), year: 1 } }];
    return ids.filter((id) => store.has(id)).map((id) => store.get(id));
  },
  deleteByIds(ids) {
    rec('VECTORIZE', 'deleteByIds', [ids]);
    for (const id of ids) store.delete(id);
    return { mutationId: `del-${ids.length}` };
  },
};

// Analytics Engine and version metadata: the data that a test must see (the local bindings of Miniflare keep nothing).
const STATS = { writeDataPoint: (p) => rec('STUB_STATS', 'writeDataPoint', [p]) };
const VERSION = { id: 'v-1', tag: 'rel', timestamp: '2026-01-02T03:04:05.678Z' };

// A workflow binding whose instance `vanishes` is there at its first `get` and gone at the next ones (`instance.not_found`):
// the functions of a kept `Instance` give `NotFound`. Any other id has an instance that does nothing.
let vanishGets = 0;
const instance = (id) => ({
  id,
  status: () => (rec('STUB_WORKFLOW', 'status', [id]), { status: 'running' }),
  pause: () => rec('STUB_WORKFLOW', 'pause', [id]),
  resume: () => rec('STUB_WORKFLOW', 'resume', [id]),
  terminate: () => rec('STUB_WORKFLOW', 'terminate', [id]),
  sendEvent: (e) => rec('STUB_WORKFLOW', 'sendEvent', [id, e]),
});
const WORKFLOW = {
  create: (o) => (rec('STUB_WORKFLOW', 'create', [o]), instance(o.id ?? 'generated')),
  get(id) {
    rec('STUB_WORKFLOW', 'get', [id]);
    if (id === 'vanishes' && vanishGets++ > 0) throw new Error('instance.not_found');
    return instance(id);
  },
};

const stubs = { STUB_AI: AI, STUB_VECTORIZE: VECTORIZE, STUB_STATS: STATS, STUB_VERSION: VERSION, STUB_WORKFLOW: WORKFLOW };
// The R2 bucket `TRACE` (checks/r2.mjs) with a record of its multipart calls (8h wave B: the upload of `pf.r2put`): each
// `createMultipartUpload`, and each `uploadPart`, `complete` and `abort` of its uploads, in `/__stub_calls`.
const traceUpload = (u) => new Proxy(u, {
  get(t, k) {
    const v = t[k];
    if (typeof v !== 'function') return v;
    if (k === 'uploadPart') return async (n, data, ...r) => (rec('TRACE', 'uploadPart', [n, data.byteLength]), t.uploadPart(n, data, ...r));
    if (k === 'complete' || k === 'abort') return async (...a) => (rec('TRACE', k, []), t[k](...a));
    return v.bind(t);
  },
});
const traceBucket = (b) => new Proxy(b, {
  get(t, k) {
    const v = t[k];
    if (typeof v !== 'function') return v;
    if (k === 'createMultipartUpload') return async (...a) => (rec('TRACE', 'createMultipartUpload', [a[0]]), traceUpload(await t.createMultipartUpload(...a)));
    return v.bind(t);
  },
});
export const withStubs = (env) => new Proxy(env, { get: (t, k) => (typeof k === 'string' && k in stubs ? stubs[k] : k === 'TRACE' ? traceBucket(Reflect.get(t, k)) : Reflect.get(t, k)) });

// `/__stub_calls`: the calls so far, as JSON. `/__stub_reset`: clear them and the Vectorize store. Null for any other path.
export function stubRoute(path) {
  if (path === '/__stub_calls') return Response.json(calls);
  if (path === '/__stub_reset') {
    calls = [];
    store = new Map();
    vanishGets = 0;
    return new Response('reset');
  }
  return null;
}

// A workflow that ends at once: its output is its parameters and its instance id.
export class Flow extends WorkflowEntrypoint {
  async run(event, step) {
    return await step.do('one', async () => ({ payload: event.payload, id: event.instanceId }));
  }
}

// A workflow that waits for the event `go`: pause, resume, terminate and `send_event!` have something to act on.
export class Waiter extends WorkflowEntrypoint {
  async run(event, step) {
    const got = await step.waitForEvent('wait for go', { type: 'go', timeout: '1 minute' });
    return { started: event.payload, got: got.payload };
  }
}
