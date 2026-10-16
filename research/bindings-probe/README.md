# Local facts of the other bindings (PLAN.md 8f, part 4, 2026-10-16)

What Miniflare 5.20261012.0-beta gives for the bindings of `platform/Ai.roc`, `Vectorize.roc`, `Analytics.roc`, `Hyperdrive.roc`, `Workflows.roc`, `Assets.roc`, `Version.roc` and `SecretsStore.roc`. `out.txt` is the output of `probe.mjs` and `wait.mjs`.

| Binding | Miniflare option | Local shape | Used by |
| --- | --- | --- | --- |
| Version metadata | `versionMetadata: 'V'` | A plain object `{ id (a random UUID), tag: "", timestamp (ISO text, the start of Miniflare) }` | `Version.metadata!` |
| Analytics Engine | `analyticsEngineDatasets: { STATS: { dataset } }` | `writeDataPoint(p)` is an empty function: it keeps nothing, so a test sees only that it does not throw. The test reads the data point from a JS stub. | `Analytics.write!` |
| Hyperdrive | `hyperdrives: { PG: 'postgres://user:secret@localhost:5432/mydb' }` | `connectionString` `postgres://user:secret@<hash>.hyperdrive.local:5432/mydb?sslmode=disable`, `host` `<hash>.hyperdrive.local`, `port` 5432, `user`, `password`, `database`. Own keys: `connectionString`, `port`, `ip`, `host`, `password`, `user`, `database`. | `Hyperdrive.config!` |
| Secrets Store | `secretsStoreSecrets: { KEY: { store_id, secret_name } }` | `get()` gives the text. A secret with no value throws `Error: Secret "nokey" not found`. The value comes from `(await mf.getSecretsStoreSecretAPI('KEY'))().create(value)`. | `SecretsStore.get!` |
| Assets | `assets: { directory, binding, run_worker_first: true, routerConfig: { has_user_worker: true } }` | Without `routerConfig.has_user_worker` the router answers (404) before the worker. `fetch(url, init)`: a file is 200 with `content-type`, `etag`, `cache-control`. No file: 404. A POST: 405. `If-None-Match` with the etag: 304. | `Assets.fetch!` |
| Workflows | `workflows: { FLOW: { name, className } }`, and the class (`extends WorkflowEntrypoint`) exported by the worker | `create({ id, params })` gives an instance with `id` (a new UUID without `id`). `get('x')` throws `Error: instance.not_found` for an id that is not there. A second `create` with an id in use throws `Error: (instance.already_exists) Workflow instance with id "dup" already exists`. `status()` is `{ status, output, __LOCAL_DEV_STEP_OUTPUTS }` (a local extra field). `terminate()` of a finished instance throws `WorkflowError: (instance.cannot_terminate) Cannot terminate instance since its on a finite state`. A workflow that waits (`step.waitForEvent`) is `running` (not `waiting`), then `paused` after `pause()`, `running` after `resume()`, `terminated` after `terminate()`, and `complete` with its output after `sendEvent({ type, payload })` with the awaited type. An event of another type changes nothing. | `Workflows` |
| Workers AI, Vectorize | `ai`, `vectorize` | Remote only (a remote proxy to Cloudflare, needs a login). Not run locally: the conformance worker has JS stubs (`conformance/bindings.js`). | `Ai`, `Vectorize` |

Files: `probe.mjs` (all but the waiting workflow), `wait.mjs` (a waiting workflow), `assets.mjs` (a POST, a HEAD, `If-None-Match`, `Range` on Assets), `assets/hello.txt`, `roc/opt.roc` (a `where` clause on a record with a type variable inside does not compile), `roc/f64.roc` (how an `F64` prints: `1.0` is `1`).

Run: `node research/bindings-probe/probe.mjs` (the same for the others).
