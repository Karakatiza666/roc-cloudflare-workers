# Design note: a test helper for apps (`js/test.mjs`)

State: accepted by talon-04 (2026-11-02), with the decisions of section 9. Plan: section 10 (release 0.0.3). No platform code is changed by this note.

Rule ids: `API.md` has no family for an app test helper. This note proposes the family `TH` (TH1 to TH19, section 5.3). It cites the existing ids `OP3` (roots `env`, `ctx`, `event`), `RN15` (the clock), `RF9` (no fake platform in Roc), `AG1` (the app sees Roc only), `M1`, `3b` (deadline sweep) and `API.md` 10.1, 10.2, 11.

## 1. Problem

`API.md` 11 says that an app tests its handlers in Miniflare with Node. The release gives no function for it. Each app writes its own harness, and each harness finds the same traps.

| # | Problem today | Evidence |
| --- | --- | --- |
| P-a | Plain Miniflare options fail: `Unrecognized keys: "modules", "script", "compatibilityDate", ...`, then `Cannot convert v4 Miniflare option "modulesRules"`. The working form (`convertV4MiniflareOptions` with an explicit module list: the entry, each `.roc-cfw/*.js`, `app.wasm` as `CompiledWasm`) is only in `conformance/run.mjs`. | Registry `PLAN.md` E2, slice 101 P2, `research/registry-plan/hello-worker/harness.mjs` |
| P-b | No supported hook to count or wrap a binding. The registry needs the D1 call count of each route (R-AP41). It subclasses the class of `makeHandler` and replaces `env.DB` in the constructor. This works only because the shim reads `this.env` at each event (`js/index.js` `run(..., { env: this.env })`). That is not documented. The conformance entry (`conformance/worker.js`) uses the same form (`withStubs(env)`, `x-waits`). | Registry E1, `worker/tests/worker-test.js` |
| P-c | The clock. Until `a6230bb` there were two clocks (slice 101 P1, slice 108 P1). Now the option `now` drives `Time.now_ms!`, `Memo`, pins and deadlines. But `now` is a function in the isolate, and the test runs in Node: a Node function cannot go into the isolate. Each harness needs its own control path (`conformance/worker.js` `/__clock?skew=`, registry `x-test-now` with `clock.js`). | `js/options.js` `now`, `conformance/checks/clock.mjs` |
| P-d | Known traps of the test setup (table below) | Slices 101, 106 |

| Trap | Effect | Fix that each harness found |
| --- | --- | --- |
| T1 (slice 101 P5) | `dispatchFetch` with a string body adds `Content-Type: text/plain;charset=UTF-8` | Send the body as bytes |
| T2 (slice 106 P3) | Node `fetch` (undici) adds `Cache-Control: no-cache` and `Pragma: no-cache` to a request with `If-None-Match` (cache mode `default` becomes `no-store`). A Worker that bypasses its cache on `no-cache` (R-AP43) then skips the cache. | `cache: 'force-cache'` on `dispatchFetch` |
| T3 (registry E9) | `wrangler d1 execute --local` and `getPlatformProxy` make `.wrangler/` dirs next to the config, also in `research/` dirs | Do not use them. Persist under a temp dir, remove it at the end |
| T4 (slice 106 P4) | Local D1 accepts any bookmark (`withSession("bookmark-abc-123")` gives no error) | No fix. A test can only record the argument |
| T5 | Miniflare makes `miniflare-*` temp dirs in `TMPDIR` and leaves them after a kill | `conformance/run.mjs` and `worker/tests/run.mjs` set `TMPDIR` to a run dir and remove it on exit, SIGINT, SIGTERM |
| T6 | With no `cf` option, Miniflare fetches `request.cf` from the network at start | `conformance/run.mjs` gives a fixed `cf` |
| T7 | A clock that jumps forward makes the next sweep (`3b`, `tasks.sweep()` at the start of each run) cancel tasks in flight past their deadline, also `Response.after` work | Not documented |
| T8 | `redirect` default `follow` of `dispatchFetch` hides a 3xx of the app | `redirect: 'manual'` |

## 2. Requirements

| # | Requirement |
| --- | --- |
| Q1 | One call starts the app in Miniflare from the built project: `app.wasm`, `.roc-cfw/`, the options file `worker.options.js` when it exists, and the Wrangler config. |
| Q2 | The helper gives `fetch`, `scheduled`, `queue` and `close`, and the handles of the local bindings to seed and read (D1, R2, KV, queue producers). |
| Q3 | A supported hook to count and to wrap a binding, for each event kind (`Fetch`, `Scheduled`, `Queue`, `Rpc`, the events of an object). No dependency on how the shim reads `this.env`. |
| Q4 | The clock: an option `now` of the helper, and a call to set it between requests. It is the one clock of the shim (option `now`, `MODULES.md` 11 "The clock"). |
| Q5 | The defaults avoid T1 to T8. |
| Q6 | No npm registry dependency for the platform. The app's test setup installs `wrangler` or `miniflare`. The helper finds it. |
| Q7 | It ships in the bundle (`js/`), is copied by `roc-cfw` to `.roc-cfw/`, and has a version that a test can check. |
| Q8 | The platform tests the helper in its own CI, with an app on the production host (not the bench host of `conformance/`). |
| Q9 | No Roc fake of the platform (`RF9`). The app code under test is the real `app.wasm` with the real shim. |

## 3. Options

### 3.1 Where the helper starts the app

| Option | How | For | Against |
| --- | --- | --- | --- |
| A1: explicit module list (as `conformance/run.mjs`) | The helper makes the module list: a test entry (text made in memory), each `.roc-cfw/*.js`, the options file and the local JS files it imports, `app.wasm` as `CompiledWasm`. `convertV4MiniflareOptions` when the Miniflare package has it. | Works today (conformance, registry W2). No build step. No `.wrangler/`. | An options file that imports an npm package needs a bundle. The helper cannot list such a module. |
| A2: Wrangler `unstable_startWorker` or `getPlatformProxy` | Wrangler reads the config and bundles with esbuild | Bundles npm imports | Makes `.wrangler/` (T3). Unstable API. Slower start. The test entry must be a file on disk. |
| A3: `wrangler dev` as a child process | HTTP on a port | The real dev path | No handles to seed D1 or R2. Slow. Port and process cleanup. |

### 3.2 The count and wrap hook (E1)

| Option | How | For | Against |
| --- | --- | --- | --- |
| B1: document the subclass form | Write in `MODULES.md` that the shim reads `this.env` at each event | No code | Freezes an internal detail. Does not cover object classes and entry points (their classes are made by `objectClass`, `entrypointClass`). |
| B2: an op log option (`onOp`) in the interpreter | `js/program.js` calls a hook for each op | Sees each crossing | A D1 query is 5 or 6 ops. The hook must know which ref came from which binding. Costs in production. |
| B3: a shim option `wrapEnv(env, info)` | `makeHandler` calls it once per event, in `run` (the one place that each event passes, `js/index.js`), after the binding check of the raw `env`. Its result is the root `env` of the task (`OP3`). | One choke point covers each kind, object classes and entry points. Plain JS. Zero cost when not given. | A new public option. An app could use it in production (allowed, but not the purpose). |

### 3.3 The clock

| Option | How | For | Against |
| --- | --- | --- | --- |
| C1: a control path | The test entry answers `POST /__cfw_test/<token>/now` before the app (a JS route: no Roc task, so no sweep, as `/__clock` of conformance). `<token>`: random for each `startApp`, so it never meets an app route. | Works for each kind: the clock is a value in the isolate, set before `scheduled` or `queue` | One extra dispatch for each change |
| C2: a request header (`x-test-now`, registry form) | The test entry reads it on `fetch` | No extra dispatch | Not for `scheduled`, `queue`, RPC. The app sees the header. |
| C3: a Miniflare binding | `bindings: { NOW }` | Simple | Fixed at start. A change is `setOptions`, which restarts the isolate and loses `Memo` state. |

### 3.4 How the helper finds Miniflare

| Order | Source | Note |
| --- | --- | --- |
| 1 | The option `miniflare`: a directory, or the module object | The app decides |
| 2 | Env `MINIFLARE`: a directory | As `conformance/run.mjs` and `worker/tests/run.mjs` |
| 3 | `miniflare`, then `wrangler/node_modules/miniflare`, resolved from the project directory (`createRequire(<dir>/package.json)`) | The app's own test setup (`npm i -D wrangler` in the app, not in the platform) |
| 4 | The global wrangler of this node: `<prefix>/lib/node_modules/wrangler/node_modules/miniflare` | The current form |
| Fail | A throw that names each place it looked, and the install command | |

The helper uses `convertV4MiniflareOptions` when the package exports it (Miniflare 5, for example `5.20261012.0-beta` of wrangler 4.151), else passes the options as they are (Miniflare 4).

## 4. Recommendation

| Part | Choice |
| --- | --- |
| Start | A1. A module that is not relative (an npm import in the options file) is a throw with the text "give it in `modules`, or bundle the options file". The option `modules` adds modules by hand. |
| Hook | B3 (`wrapEnv`), and the helper uses it. The helper gives a built-in count for the declared bindings (`count`), and a `hooks` module for a custom wrap. B1 is not documented: the subclass form stays possible, not supported. |
| Clock | C1. The helper option `now` (ms, or `null` for the real clock) and `app.setNow(ms)`, `app.advance(ms)`. Inside the isolate: `now: () => fixed ?? Date.now()`. T7 is documented in the helper doc. |
| Bindings | From the manifest of `app.wasm` (`manifestOf` in Node, as `sync`), so the helper knows each declared D1, KV, R2, queue, object class. The option `d1`, `kv`, `r2`, ... only seeds. A declared binding with no seed is still made (empty). |
| Ship | `js/test.mjs` (Node part, `.mjs`, so the module lists of `*.js` never take it, as `cli.mjs`) and `js/test-entry.js` (the part in the isolate). Both in the bundle. `roc-cfw shim` copies them with the rest of `js/`. |
| Version | `js/cfw.json` gets `"test": 1`. `test.mjs` exports `TEST_API = 1`. A breaking change of `startApp` adds 1. |

## 5. API sketch

### 5.1 Node side (`.roc-cfw/test.mjs`)

```js
import { startApp } from './.roc-cfw/test.mjs';

const app = await startApp({
  dir: '.',                       // the project: app.wasm, .roc-cfw/, worker.options.js, wrangler.toml
  wasm: 'app.wasm',               // default: the import of the `main` entry of the config, else app.wasm
  now: 1767225600000,             // the shim clock at start; null: the real clock (default)
  d1: { DB: ['sql/0001_init.sql', 'tests/seed.sql'] },   // SQL files or texts, run in order
  kv: { CACHE: { key: 'value' } },
  r2: { BUCKET: { 'a/b.txt': 'bytes or text' } },
  queues: { JOBS: { maxBatchSize: 10 } },                 // producer and consumer settings
  outbound: { 'GET https://api.github.com/repos/o/r': [{ status: 200, body: '{}' }, { status: 304 }] }, // answers in order (TH18), or a Node function
  services: { GITHUB: (request) => new Response('...') }, // service bindings as Node functions
  bindings: { AUDIENCE: 'talon' },                        // vars and secrets
  compatibility: { date: '2026-10-01', flags: ['enable_request_signal'] }, // default: the Wrangler config
  count: ['DB'],                  // bindings to count (TH6)
  hooks: 'tests/hooks.js',        // optional module in the isolate (TH7)
  options: { taskDeadlineMs: 3000 }, // makeHandler options on top of worker.options.js (not `now`, `wrapEnv`)
  miniflare: undefined,           // TH10
  persist: false,                 // false: in memory; true: under the run dir, removed at close
  modules: [],                    // extra modules: { type, path, contents }
  cf: undefined,                  // default: a fixed request.cf (no network)
});

const res = await app.fetch('/v1/releases/x', { method: 'POST', body: '{"a":1}', headers: { 'content-type': 'application/json' }, now: 1767229200000 });
res.status; await res.text();
res.calls;                        // { DB: { n: 1, ops: ['all'], list: [{ op: 'all', session: 'first-unconstrained' }] } } (TH6, TH16)
res.sessions;                     // { DB: ['first-unconstrained'] }: the withSession arguments (T4)

await app.setNow(1767229200000);  // the clock (TH5)
await app.advance(60_000);

const run = await app.scheduled({ cron: '*/5 * * * *', time: 1767225600000 }); // { outcome, noRetry }
const q = await app.queue('jobs', [{ id: '1', body: { x: 1 } }]);  // { outcome, ackAll, retryBatch, explicitAcks, retryMessages }

const db = await app.d1('DB');    // the Miniflare D1 handle: prepare, batch, exec
const kv = await app.kv('CACHE'); const r2 = await app.r2('BUCKET'); const p = await app.queueProducer('JOBS');
app.calls({ reset: true });       // all counted calls since the last reset, of any task
await app.idle();                 // waits until the task table is empty (Response.after work, alarms)
await app.sql('DB', ["UPDATE releases SET checked_at = 0"]);   // SQL between requests (TH19)
app.outbound();                   // { log: ['GET https://...'], count: { 'GET https://...': 2 }, unmatched: [] } (TH18)
await app.reset();                // D1, KV, R2, Cache API, clock, pins back to the start (TH15)
app.logs;                         // the structured log lines of workerd
await app.close();                // dispose Miniflare, remove the run dir
```

| Signature | Rule |
| --- | --- |
| `startApp(opts) -> Promise<App>` | TH1, TH2 |
| `app.fetch(pathOrUrl, init?) -> Promise<Response & { calls, sessions }>`. `init.now`: the clock before the request | TH3, TH4, TH5 |
| `app.setNow(ms \| null) -> Promise<void>`, `app.advance(ms) -> Promise<void>` | TH5 |
| `app.scheduled({ cron?, time?, now? }) -> Promise<{ outcome, noRetry }>` | `/cdn-cgi/local/scheduled?...&format=json` with `unsafeTriggerHandlers` (as `API.md` 11). `cron` default: the first of the manifest `crons`. |
| `app.queue(name, messages) -> Promise<QueueResult>` | `(await mf.getWorker()).queue(name, messages)` (as `conformance/checks/queue.mjs`). A message with no `timestamp` gets the helper clock. |
| `app.d1(name)`, `app.kv(name)`, `app.r2(name)`, `app.queueProducer(name)`, `app.object(name)` | The Miniflare handles (`getD1Database`, ...) |
| `app.calls({ reset? }) -> { [binding]: { n, ops } }` | TH6 |
| `app.idle(ms = 5000) -> Promise<void>` | TH8 |
| `app.sql(name, texts) -> Promise<void>` | TH19 |
| `app.outbound() -> { log, count, unmatched }` | TH18 |
| `app.reset() -> Promise<void>` | TH15 |
| `app.mf`, `app.url` | The Miniflare instance and its URL: the escape hatch, no promise of stability |
| `app.close() -> Promise<void>` | TH9 |

### 5.2 Isolate side (`js/test-entry.js`) and the shim option

The helper makes the entry text in memory, from the manifest, as `entryOf` of `cli.mjs` does, with two more lines:

```js
import app from './app.wasm';
import { makeHandler, objectClass } from './.roc-cfw/index.js';
import { testEntry } from './.roc-cfw/test-entry.js';
import options from './worker.options.js';   // only when the file exists
import * as hooks from './tests/hooks.js';     // only with `hooks`
export const Room = objectClass('Room');
const t = testEntry({ token: '<random>', now: 1767225600000, count: ['DB'], hooks });
export default t.wrap(makeHandler(app, { ...options, now: t.now, wrapEnv: t.wrapEnv }));
```

New shim option (in `js/options.js` `RULES`):

| Option | Value | Rule |
| --- | --- | --- |
| `wrapEnv` | `(env, info) => env`. `info`: `{ kind, name, event }` (`kind` as the task context: `Fetch`, `Scheduled`, `Queue`, `Email`, `Tail`, `Rpc`, `Init`, `Alarm`, `Socket`, `Other`; `name`: the log tag, for example `fetch`, `Room.alarm`; `event`: the root `event`). | TH11 |

`t.wrap(Handler)` gives a subclass whose `fetch` answers `/__cfw_test/<token>/...` (the clock, the counts, the task table for `idle`) and else calls `super.fetch`. It is platform code, so the platform owns its dependency on the class.

### 5.3 Rules (proposed family TH)

| Id | Rule |
| --- | --- |
| TH1 | `startApp` reads the manifest of the wasm in Node (`manifestOf`). It refuses to start (a throw with the name) when a seed names a binding that the manifest does not declare, or when the app has no `.roc-cfw/index.js` (the text: run `roc-cfw sync`). |
| TH2 | Each declared binding of a kind that Miniflare has locally (`d1`, `kv`, `r2`, `queue`, `object` of this Worker) is made, seeded or empty. An object class is SQLite-backed (`useSQLite: true`, `MODULES.md` 7). A kind with no local form (`ai`, `vectorize`, ...) needs `services` or `hooks`. |
| TH3 | `app.fetch` defaults: a text body is sent as UTF-8 bytes (no implicit `Content-Type`, T1); `cache: 'force-cache'` when the caller gives no `cache` (T2); `redirect: 'manual'` (T8); a path is joined to `http://localhost`. The caller can give each one. |
| TH4 | `res.calls` and `res.sessions` hold the calls of the tasks of this request only. The helper sets the header `cfw-test-request: <n>`; the test entry keys the counts by it. Calls of other tasks (an object that the request called, `Response.after` work after the response) go to `app.calls()` only. |
| TH5 | The helper clock is the shim option `now`, in the isolate. `setNow` and `advance` go through the control path. No Roc task runs for them, so no sweep. A jump forward cancels the tasks in flight past their deadline at the next sweep (T7). `Date.now()` of JS, the Cache API `max-age`, and alarm times of Workers stay on the real clock. |
| TH6 | `count: [names]` counts the calls of each named binding, in `wrapEnv`. A call is one round trip to the binding: D1 `all`, `run`, `first`, `raw` of a statement, `batch`, `exec` (`prepare`, `bind`, `withSession` are not calls; `withSession` arguments go to `sessions`); KV `get`, `getWithMetadata`, `put`, `delete`, `list`; R2 `get`, `head`, `put`, `delete`, `list`, `createMultipartUpload`, `resumeMultipartUpload`; a queue `send`, `sendBatch`. `ops` lists the method names in order. |
| TH7 | `hooks`: a module in the isolate. Its exports `wrapEnv(env, info)` and `fetch(request, env, next)`, when present, run after the built-in count. It is the supported custom wrap (E1). |
| TH8 | `app.idle()` waits until the shim task table has no task, through the control path. A timeout is a throw with the count. |
| TH9 | The run dir (`TMPDIR` of Miniflare, the persist dirs) is `<os tmp>/cfw-test-<pid>-<n>`. `close` removes it. The helper also removes it at `exit`, `SIGINT`, `SIGTERM` (as `conformance/run.mjs`). The helper never makes a `.wrangler/` dir (T3). |
| TH10 | The helper finds Miniflare in the order of 3.4. It reads no npm registry. |
| TH11 | `wrapEnv` runs once per event, in `run` of `js/index.js`, after the binding check of the raw `env` (`MODULES.md` 3). Its result is the root `env` of the task (`OP3`), so `Get(Root("env"), name)` and `envRead` see the wrapped value. A throw in it fails the event as a throw of the event. |
| TH12 | The default `cf` is the fixed placeholder of `conformance/run.mjs` (T6). |
| TH13 | `.roc-cfw/test.mjs` exports `TEST_API`, equal to `test` of `cfw.json`. |
| TH14 | `startApp` gives the same answers as `wrangler dev` for the same app and requests, apart from T4 and the clock. |
| TH15 | `app.reset()` keeps the isolate and the wasm. It clears D1 (drops the user tables, then runs the `d1` seeds again), KV and R2 (list and delete), the Cache API (the keys that the app put, recorded by the test entry; if probe P2 fails, a `setOptions` restart for an app that uses the cache), the clock (back to the `now` of the start), and the shim pin table (`Memo`, `Js.pin!`) when probe P3 passed. It waits for `idle` first. Module globals of the app's JS (`ops`, `hooks`) have no guarantee. |
| TH16 | Each counted call is recorded as `{ op, session }` in `res.calls.<name>.list`. `session` is the `withSession` argument of the session that made the call, or `null`. |
| TH17 | The option `wasm` is any path. The generated entry imports it as `./app.wasm`; the helper reads the bytes from the path. The shim is `.roc-cfw/` of `dir`, or the option `shim` (a dir). |
| TH18 | `outbound` is a Node function, or a table `{ 'METHOD url': [answer, ...] }`. An answer is a `Response`, or `{ status, headers, body }`. Each request to a key takes the next answer; after the last, the last again. A request with no key is a 599 answer and an error in `app.outbound().unmatched`. `app.outbound()` gives `{ log, count, unmatched }`. |
| TH19 | `app.sql(name, texts)` runs SQL texts on a D1 binding in order, with the split rules of the seeds. |

## 6. How it ships

| Item | Rule |
| --- | --- |
| Files | `js/test.mjs` (Node), `js/test-entry.js` (isolate). Wrangler bundles only the modules that `main` imports, so a deploy never takes `test-entry.js`. |
| Copy | `roc-cfw shim` copies `js/` to `.roc-cfw/` as now. No change in `roc-cfw`, if it ignores an unknown key of `cfw.json` (open question O4). |
| Version | `cfw.json`: `{ "api": 1, "test": 1 }`. The helper API follows the semver of the platform release. |
| Dependency | None at the platform level. The app's `package.json` (or a global install) has `wrangler` or `miniflare`. The README names the tested Miniflare versions. |
| Doc | A section "Test your app" in `README.md` and a row in `MODULES.md` 3 for `wrapEnv`. The trap table T1 to T8 goes in the helper doc. |

## 7. Test plan (platform)

The helper is tested with an app on the production host, not on the bench host of `conformance/`.

| Test | What | Where |
| --- | --- | --- |
| H1 | `examples/hello` (built by `tln run hello`): `startApp`, one `fetch`, D1 seed and read, `close`. The run dir is gone, and no `.wrangler/` is in `examples/hello/`. | `js/test/helper-test.mjs` |
| H2 | A small app `js/test/helper-app/` (production platform): routes for D1, KV, R2, `Time.now_ms!`, a `Memo` with a max age, a queue consumer, a cron, one object class with an alarm, `Response.after` | same |
| H3 | T1: a text body arrives with no `Content-Type`. T2: a request with `If-None-Match` arrives with no `Cache-Control`. T8: a 302 is seen. | same |
| H4 | The clock: `setNow` moves `Time.now_ms!`; `advance(61_000)` expires a `Memo` of 60 s; `scheduled` and `queue` see the set time | same |
| H5 | Counts: a route with 1 `batch` and 2 `all` gives `n: 3`; `prepare` and `bind` give 0; an object call and `after` work go to `app.calls()` and not to `res.calls` | same |
| H6 | `wrapEnv` reaches each kind: `Fetch`, `Scheduled`, `Queue`, `Init`, `Alarm`, `Rpc` (one counter for each kind) | same, and a Node unit test of `js/index.js` with the stand-in class |
| H7 | Miniflare discovery: `MINIFLARE` set, a local `node_modules/miniflare`, the global wrangler, none (the throw names the places) | same |
| H8 | `SIGTERM` during a run: the run dir is gone (as `conformance/tmpdir-test.sh`) | `js/test/helper-tmpdir.sh` |
| H9 | `reset`: after writes to D1, KV, R2, a cache entry, a `Memo` value and a clock change, each read is as after the start | `js/test/helper-test.mjs` |
| H10 | 20 resets against 20 starts: the time is printed (no fail limit) | same |
| H11 | The outbound table: 3 requests to one key with 2 answers give answer 1, 2, 2; the count is 3; a request with no key is in `unmatched` | same |

Revert checks (5 tricky ones): drop the bytes conversion (H3 T1 fails); drop `force-cache` (H3 T2 fails); call `wrapEnv` in `Handler.fetch` only and not in `run` (H6 `Alarm` and `Init` fail); key the counts globally, not by request (H5 fails); key the run dir by pid only (two `startApp` in one process share it, and the first `close` breaks the second: a test with two apps fails).

## 8. How the registry moves to it

| Registry part today (`worker/tests/`) | With the helper |
| --- | --- |
| Need of the registry (review items a to h) | Registry part today (`worker/tests/`) | With the helper |
| --- | --- | --- |
| (a) A clock that each request can set | `clock.js` (`Date.now` override) and the header `x-test-now` | `app.fetch(path, { now: ms })`: the helper sets the shim clock through the control path before it sends the request (TH5). `clock.js` is removed (also follow-up W1). The registry reads time through `Time.now_ms!` only (R-WH4), so the `Date.now` override is not needed. |
| (b) SQL on the D1 of the case between requests | The `sql` lines of `requests.jsonl`, run with `mf.getD1Database('DB')` | `await (await app.d1('DB')).prepare(sql).run()` between two `app.fetch` calls, or `app.sql('DB', [texts])` (TH19) |
| (c) The D1 session argument of each call | `x-d1-session` (the last `withSession` argument of the request) | `res.calls.DB.list`: one item for each call, `{ op, session }`. `session` is the `withSession` argument of the session that made the call (a bookmark, `first-unconstrained`, `first-primary`), or `null` with no session (TH16). `res.sessions.DB`: each `withSession` argument in order. |
| (d) The D1 call count per request | `x-d1-calls`, `x-d1-ops` from the subclass with a D1 proxy | `count: ['DB']`, then `res.calls.DB.n` and `res.calls.DB.ops` (TH4, TH6). `worker-test.js` is removed. |
| (e) `cache: 'force-cache'` by default | `dispatchFetch(..., { cache: 'force-cache', redirect: 'manual' })`, `Buffer.from(body)` | The defaults of `app.fetch` (TH3) |
| (f) An outbound handler: a list of answers in order for repeated requests to the same URL, and a count per URL | `fakeGithub(c, github, errs)` with `github.log` | `outbound: { 'GET https://api.github.com/repos/o/r': [answer1, answer2] }`: the answers in order, the last one again after the end (TH18). `app.outbound()` gives the log (`METHOD url` in order) and the count per URL. A function form stays for other needs. |
| (g) The Cache API, real in Miniflare, with a reset | A new Miniflare for each case | The real Cache API of Miniflare. `app.reset()` clears it (TH15). |
| (h) A wasm path (`.work/worker/<stamp>/app.wasm`) | The module list reads the wasm from `w2Dir` | `startApp({ dir: 'worker', wasm: '.work/worker/<stamp>/app.wasm' })`. The wasm path is free; the shim is `.roc-cfw/` of `dir` or the option `shim` (TH17). |
| The `/__test/*` self-test paths | Answered by `worker-test.js` | A `hooks` module with `fetch(request, env, next)`: the same JS answers (TH7) |
| Module list, `convertV4MiniflareOptions`, `MINIFLARE`, run dir, signals | In `run.mjs` | Removed. `startApp({ ... })` |
| Migrations and `seed.sql` | Run by hand on `d1Persist` | `d1: { DB: [...migrations, seed] }`. `app.d1('DB')` for `expect/db.tsv`. |
| Cron | `/cdn-cgi/local/scheduled` with `x-test-now` | `await app.scheduled({ cron, time: t, now: t })` |

With items (a) to (h), `worker/tests/worker-test.js` and `worker/tests/clock.js` can go. Step order: the platform releases the helper in 0.0.3 (section 10). A registry slice changes `run.mjs` only. The cases and `expect/` files stay byte for byte, so the W2 run before and after the move must give the same PASS list.

## 9. Decided questions (review by talon-04, 2026-11-02)

All questions are decided. The note was accepted with these answers.

| # | Question | Decision |
| --- | --- | --- |
| O1 | The header `cfw-test-request` stays visible to the app (an incoming request is immutable; a new `Request` may lose `request.signal`). Is that acceptable? | Acceptable: the registry ignores unknown headers (R-AP44). The helper strips the header before the app sees it if a probe shows that `new Request(req, { headers })` keeps `request.signal` in workerd. The probe is the first build step (step S1). |
| O2 | An options file that imports an npm package (A1 cannot list it) | As proposed: a throw with the text. Later: an esbuild step if the app has esbuild. |
| O3 | What does production D1 do with a bookmark that it never made (T4)? | Record only. No strict mode. |
| O4 | Does `roc-cfw shim` accept a new key in `cfw.json` (`test`)? | As proposed: check the `roc-cfw` source. If it refuses the key, a `roc-cfw` patch release comes first (step S7). |
| O5 | Should `wrapEnv` be allowed in production, or only with a test flag? | Allowed in production. The registry uses it only in tests. |
| O6 | The tested Miniflare range, and where it is written | As proposed: the README, from the CI pin (`wrangler@4.151.0`). |
| O7 | Does the helper set `process.env.TMPDIR`? | As proposed: set it once, at the first `startApp`, to a parent dir that the helper owns, and restore it at the last `close`. |
| O8 | One Miniflare per test, or one per file with a reset call? | One Miniflare per `startApp` in the first version, and `app.reset()` early in the plan (step S5, rule TH15). Reason: the registry W2 step has 68 cases, and about 0.5 s of the 0.75 s of a case is the start, the migrations and the seed. |

## 10. Implementation plan (release 0.0.3)

The steps are in order. Each step ends green (its tests pass) before the next step starts. The revert checks are the tricky ones only (5 to 10 in all, per step at most 2).

| Step | Change | Tests | Revert checks |
| --- | --- | --- | --- |
| S1 | Probes in `research/test-helper-probe/` (workerd through Miniflare): P1 `new Request(req, { headers })` keeps `request.signal` (abort the client, see the task cancel `signal`); P2 the test entry can wrap `globalThis.caches` (`default.put`, `open`) and the app's `Get(Root("global"), "caches")` sees the wrap; P3 the shim pin table can be cleared from a JS route when the task table is empty, and the next `Memo` read loads again. | The probe output, written in this note (sections 5.3 and 10). P1 decides O1, P2 the cache reset form of TH15, P3 the `Memo` part of TH15. | None (probes) |
| S2 | The shim option `wrapEnv` (`js/options.js` `RULES`, the call in `run` of `js/index.js`, after `checkEnv` of the raw `env`, TH11). A row in `MODULES.md` 3 and in the shim options table of `PLAN.md`. | Node unit test with the stand-in class (`bench/cf-node.mjs`): one counter for each kind (`Fetch`, `Scheduled`, `Queue`, `Rpc`, `Init`, `Alarm`, `Socket`); the binding check still sees the raw `env`. Conformance: one check that a wrapped D1 counts the calls of a route. | Call `wrapEnv` in `Handler.fetch` only (the `Init` and `Alarm` counters stay 0). |
| S3 | `js/test-entry.js`: the control path `/__cfw_test/<token>/` (clock `now`, `calls`, `tasks`, `reset`), the clock cell, the count and session record (TH6, TH16), the header strip of O1 (when P1 passed), the `hooks` module (TH7), the cache key record (when P2 passed). | Node unit test of the count rules of TH6 (a fake D1, KV, R2 with plain objects): `prepare` and `bind` are not calls, `batch` is 1, the session of each call is recorded. | Count `prepare` as a call. |
| S4 | `js/test.mjs` `startApp`: Miniflare discovery (TH10), the module list from the `wasm` path and the shim dir (TH17), the manifest bindings (TH1, TH2), the seeds, the run dir and the signals (TH9), `fetch` defaults (TH3) and its `now` field (TH5), `scheduled`, `queue`, the outbound script (TH18), `close`. | H1, H3, H4, H5, H7, H8 of section 7, with `js/test/helper-app/` (production platform) and `examples/hello`. | Drop the text-to-bytes conversion of the body (H3 T1 fails). Key the run dir by pid only (two `startApp` in one process: the first `close` breaks the second). |
| S5 | `app.reset()` (TH15): D1 (drop the user tables, run the seeds again), KV and R2 (list and delete), the Cache API (delete the recorded keys, or the fallback of TH15), the clock, the shim pin table (when P3 passed). | H9: a case writes D1, KV, R2, a cache entry and a `Memo` value, then `reset`, then each read is as after the start. H10: 20 resets in a row take less than 20 starts (time printed, no fail limit). | Skip the cache keys of `caches.open` names (only `caches.default`): the H9 cache read of a named cache fails. |
| S6 | `app.idle()`, `app.calls()`, `app.logs`, `services`, `hooks` | H2, H6 | None |
| S7 | `js/cfw.json` `"test": 1`, `TEST_API` (TH13). Check O4 in `roc-cfw`. README section "Test your app" with the trap table T1 to T8 and the Miniflare range (O6). | `roc-cfw shim` of a bundle with the new key copies `test.mjs` and `test-entry.js` | None |
| S8 | CI: the helper tests in the platform CI (a step after the build of `examples/hello` and `helper-app`) | The CI run | None |

After 0.0.3: a registry slice moves `worker/tests/run.mjs` to the helper (section 8), with `reset` between cases of the same seed.
