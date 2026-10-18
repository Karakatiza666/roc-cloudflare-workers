// The bindings of the manifest (MODULES.md 3): `Worker.new({ bindings: [db.declare(), ...] })` in Roc. For each kind:
// what `env[name]` must have (the check of `makeHandler`), and its part of the Wrangler config (`roc-cloudflare-workers
// sync`). `has`: functions of the binding; `text`: a property that is a string.
//   kind            Roc                                Wrangler config
//   d1              D1.binding                         [[d1_databases]] binding
//   kv              Kv.json, Kv.text, Kv.bytes         [[kv_namespaces]] binding
//   r2              R2.binding                         [[r2_buckets]] binding
//   object          Object.namespace                   [[durable_objects.bindings]] name, class_name, script_name
//   service         Service.binding, binding_with      [[services]] binding, service, entrypoint
//   queue           Queue.json, text, bytes, v8        [[queues.producers]] binding
//   email           Email.binding                      [[send_email]] name
//   workflows       Workflows.json                     [[workflows]] binding
//   vectorize       Vectorize.json                     [[vectorize]] binding
//   ai              Ai.binding                         [ai] binding
//   analytics       Analytics.binding                  [[analytics_engine_datasets]] binding
//   assets          Assets.binding                     [assets] binding
//   hyperdrive      Hyperdrive.binding                 [[hyperdrive]] binding
//   ratelimit       RateLimit.binding                  [[ratelimits]] name
//   version         Version.binding                    [version_metadata] binding
//   secrets_store   SecretsStore.binding               [[secrets_store_secrets]] binding
// `section`: the path of the config part; `many`: an array of tables; `key`: the field with the binding name;
// `fill`: the other fields, as TOML values (a `<...>` value is for the user to fill).
export const BINDING_KINDS = {
  d1: { what: 'a D1 database', has: ['prepare', 'batch'], section: 'd1_databases', many: true, key: 'binding', fill: (b) => ({ database_name: '"<database name>"', database_id: '"<the id of wrangler d1 create>"' }) },
  kv: { what: 'a KV namespace', has: ['get', 'put', 'getWithMetadata'], section: 'kv_namespaces', many: true, key: 'binding', fill: () => ({ id: '"<the id of wrangler kv namespace create>"' }) },
  r2: { what: 'an R2 bucket', has: ['head', 'put', 'createMultipartUpload'], section: 'r2_buckets', many: true, key: 'binding', fill: () => ({ bucket_name: '"<bucket name>"' }) },
  object: { what: 'a Durable Object namespace', has: ['idFromName', 'newUniqueId'], section: 'durable_objects.bindings', many: true, key: 'name', fill: (b) => ({ class_name: q(b.class), ...(b.script ? { script_name: q(b.script) } : {}) }) },
  service: { what: 'a service binding', has: ['fetch'], section: 'services', many: true, key: 'binding', fill: (b) => ({ service: b.service ? q(b.service) : '"<the name of the Worker>"', ...(b.entrypoint ? { entrypoint: q(b.entrypoint) } : {}) }) },
  queue: { what: 'a queue producer', has: ['send', 'sendBatch'], section: 'queues.producers', many: true, key: 'binding', fill: () => ({ queue: '"<queue name>"' }) },
  email: { what: 'a send_email binding', has: ['send'], section: 'send_email', many: true, key: 'name', fill: () => ({}) },
  workflows: { what: 'a Workflows binding', has: ['create', 'get'], section: 'workflows', many: true, key: 'binding', fill: () => ({ name: '"<workflow name>"', class_name: '"<the WorkflowEntrypoint class>"' }) },
  vectorize: { what: 'a Vectorize index', has: ['query', 'upsert'], section: 'vectorize', many: true, key: 'binding', fill: () => ({ index_name: '"<index name>"' }) },
  ai: { what: 'a Workers AI binding', has: ['run'], section: 'ai', many: false, key: 'binding', fill: () => ({}) },
  analytics: { what: 'an Analytics Engine dataset', has: ['writeDataPoint'], section: 'analytics_engine_datasets', many: true, key: 'binding', fill: () => ({ dataset: '"<dataset name>"' }) },
  assets: { what: 'an assets binding', has: ['fetch'], section: 'assets', many: false, key: 'binding', fill: () => ({ directory: '"./public"' }) },
  hyperdrive: { what: 'a Hyperdrive config', text: 'connectionString', section: 'hyperdrive', many: true, key: 'binding', fill: () => ({ id: '"<the id of wrangler hyperdrive create>"' }) },
  ratelimit: { what: 'a rate limit binding', has: ['limit'], section: 'ratelimits', many: true, key: 'name', fill: () => ({ namespace_id: '"<an integer as text>"', simple: '{ limit = 100, period = 60 }' }) },
  version: { what: 'a version metadata binding', text: 'id', section: 'version_metadata', many: false, key: 'binding', fill: () => ({}) },
  secrets_store: { what: 'a Secrets Store secret', has: ['get'], section: 'secrets_store_secrets', many: true, key: 'binding', fill: () => ({ store_id: '"<store id>"', secret_name: '"<secret name>"' }) },
};

const q = (s) => JSON.stringify(s);

// The config part of one binding, as TOML text: `[[d1_databases]]\nbinding = "DB"\n...`.
export function tomlOf(b) {
  const k = BINDING_KINDS[b.kind];
  const head = k.many ? `[[${k.section}]]` : `[${k.section}]`;
  const fields = { [k.key]: q(b.name), ...k.fill(b) };
  return [head, ...Object.entries(fields).map(([f, v]) => `${f} = ${v}`)].join('\n');
}

// The problems of `env` for the bindings of the manifest: one line each, none when all are there with their kind. A
// service binding has a function for each name (an RPC stub), so it passes the check of each kind with `has`.
export function bindingProblems(bindings, env) {
  const out = [];
  for (const b of bindings) {
    const k = BINDING_KINDS[b.kind];
    const v = env?.[b.name];
    if (v === undefined || v === null) {
      out.push(`${b.name} (${b.kind}): env has no ${b.name}. Add ${k.many ? `[[${k.section}]]` : `[${k.section}]`} with ${k.key} = "${b.name}" to the Wrangler config.`);
      continue;
    }
    const missing = k.text ? (typeof v[k.text] === 'string' ? null : k.text) : k.has.find((m) => typeof v[m] !== 'function');
    if (missing) out.push(`${b.name} (${b.kind}): env.${b.name} is not ${k.what} (it has no ${missing}). Check its part of the Wrangler config.`);
  }
  return out;
}
