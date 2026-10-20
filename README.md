# cloudflare-workers

A Roc platform for Cloudflare Workers. The app compiles to a wasm32 reactor. The host is in Zig. Effects (fetch, D1, R2, KV, Cache API, Durable Object SQL) are direct-style hosted functions that wait on JS promises through JSPI.

Status: phases A and B are built (`PLAN.md`). The release files are made by `scripts/bundle.sh` and published by `.github/workflows/release.yml` (`PLAN.md` 11). No release exists yet.

| Document | Content |
| --- | --- |
| `API.md` | The app API: events, `Js` values, programs, the contract |
| `MODULES.md` | Each platform module: what it does, its errors, its limits |
| `PLAN.md` | The build plan, the status of each step, the measurements |
| `examples/hello/` | A Worker project that uses a release |

## What a release has

Each release (tag `X.Y.Z`) has 2 files. They have the same version and are used together.

| File | Use |
| --- | --- |
| `<hash>.tar.zst` | The platform bundle. It goes in the header of the app. It has the Roc modules, `LICENSE` and the production host `targets/wasm32/host.wasm`. The packages `http` (roc-lang/http 2.0.0) and `cbor` (roc-cbor 0.2.1) stay URLs in the platform header: Roc downloads them. |
| `roc-cloudflare-workers-X.Y.Z.tgz` | The JS shim, as an npm package (`makeHandler`, `objectClass`, `entrypointClass`), and the command `roc-cloudflare-workers` (`init`, `sync`). `npm install <file or URL>` takes it. |

The release notes have both URLs. The package is not on the npm registry: the version of the shim must be the version of the platform, so the shim comes from the same release.

Needs: a Roc nightly (the release notes name it, `compat/last-stack-first-nightly` is the one that the release was built with), Node and `wrangler` (the tests use Node 26 and Wrangler 4).

## Use it

A project has four files: `app.roc`, `worker.js`, `wrangler.toml`, `package.json`. The command `roc-cloudflare-workers` of the shim package makes them:

| Command | What it does |
| --- | --- |
| `roc-cloudflare-workers init [dir]` | Writes the four files of a new project (`examples/hello`), with the URLs of the release of the package. |
| `roc-cloudflare-workers sync` | Reads the manifest of `app.wasm`, writes `worker.js` (one export line for each class, then `makeHandler`), and checks `wrangler.toml`: `main`, the compatibility date and flags, `durable_objects.bindings`, `migrations` (`new_sqlite_classes`), the bindings of `Worker.new({ bindings })`, `triggers.crons` of `Worker.new({ crons })`. It prints the parts to add and gives exit 1 when one is missing or wrong. `--check`: write nothing (for CI). |

```sh
npx --yes --package=https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/X.Y.Z/roc-cloudflare-workers-X.Y.Z.tgz roc-cloudflare-workers init my-worker
cd my-worker
npm install
npm run build     # roc build, then roc-cloudflare-workers sync
npm run dev       # wrangler dev --local
```

The steps below say what each file has.

1. The app (`examples/hello/app.roc`). The header has the platform and nothing else. The platform brings `Http`, `Cbor` and the types of `roc-lang/http`: the app has no `http` and no `cbor` entry.

```roc
app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/X.Y.Z/<hash>.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "hello from Roc"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
```

| What the app writes | Meaning |
| --- | --- |
| `app [event!]` | The one function that takes every event (`API.md` 10.1). |
| `Worker.new({ fetch!, scheduled!, queue!, ... })` | A record with the handlers that the app has, each with its own error type. One field: `Worker.new({ fetch!: fetch! })` (`{ fetch! }` alone is a block). `worker.event!` sends each event to its handler. A kind with no handler is `Unhandled`. |
| `import pf.D1`, `pf.R2`, `pf.Kv`, ... | The modules of `MODULES.md`. A binding is `D1.binding("DB")`: the name is the name in the Wrangler config. A Durable Object namespace takes its class value: `Object.namespace("ROOMS", { class: room })`, with `room = Object.class("Room", ...)`. For a class of another Worker: `Object.namespace_remote("FAR", { class: "Room", script: "other" })`. |
| `Worker.new({ ..., bindings: [db.declare(), rooms.declare()] })` | The bindings that the app uses, in the manifest (`MODULES.md` 3). The shim checks at load that `env` has each one with its kind, and `sync` checks the Wrangler config. Optional. |
| `Worker.new({ ..., crons: [Worker.cron("*/5 * * * *", settle!)] })` | A handler for each cron expression, in place of one `scheduled!` that matches `s.cron()`. `sync` checks `triggers.crons`. `scheduled!` stays: it gets the runs of the other crons. |
| `req.method()`, `req.url()`, `res.status()` | `Request`, `Response` and the payloads of the handlers are opaque: the app reads them with methods, and a field read does not compile (`MODULES.md` MC15). A function with no argument is `f!()` (MC14). |
| `import pf.Cbor` | Typed data as CBOR. It wraps roc-cbor, so no `cbor` entry. An app may add the same roc-cbor URL: the types are the same. |

2. Build the app. Use `--no-cache`, so that each build of the same source gives the same bytes: a build with a warm build cache gives other bytes than a clean build (`research/no-cache-repro/README.md`). No wrong behavior of a warm build is known (the conformance run passes on both), but a release and a test must build what a clean machine builds.

```sh
roc build --target=wasm32 --no-cache --output=app.wasm app.roc
```

A `roc build` with type errors still writes the `.wasm` file. It prints "N errors and 0 warnings found ... while successfully building" and exits with 1 (checked 2026-10-20 with one bad line). A build is good only when the exit code is 0 and the text is "0 errors and 0 warnings". A script must check the exit code. In the repo, run the command from the root (a build inside `examples/auction/` gives `PathOutsideWorkspace`).

3. The shim. `npm install https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/X.Y.Z/roc-cloudflare-workers-X.Y.Z.tgz`. The entry of the Worker (`examples/hello/worker.js`) is the file that `roc-cloudflare-workers sync` writes:

```js
// Made by roc-cloudflare-workers sync from the manifest of the app. Run it again after a change of the classes in Roc.
import app from './app.wasm';
import { makeHandler } from 'roc-cloudflare-workers';

export default makeHandler(app);
```

`makeHandler(module, opts)` throws at load for a bad option, a module that is not stack-first, a class with no export line, and a binding of `Worker.new({ bindings })` that is not in `env` with its kind. The options are in `js/options.js`. A Durable Object class or a named entry point of the app is one export line before the default export (`objectClass("Room")`, `entrypointClass("Admin")`, `API.md` AQ10): `sync` writes these lines. An app with options writes its own entry file: `sync` does not write over a file that it did not make, and prints the lines.

4. The Wrangler config (`examples/hello/wrangler.toml`):

| Setting | Value | Why |
| --- | --- | --- |
| `main` | The `worker.js` of step 3 | Wrangler compiles the `app.wasm` import itself. |
| `compatibility_date` | `2026-10-01` or newer | The date of the tests (`conformance/run.mjs`). |
| `compatibility_flags` | `["enable_request_signal"]` | Without it `request.signal` never fires: a task does not stop when the client goes away (`API.md` 10.2). |
| `compatibility_flags` (the same list) | `"global_fetch_strictly_public"` too | Without it a `fetch` of another Worker of your account on workers.dev gives 404 `error code: 1042` on the edge (local runs do not show it). With it, `fetch` goes to the public internet. For a Worker of your account, a service binding is the other way. |
| Bindings | Names that the app uses in `X.binding("NAME")` | One binding for each name. `sync` prints the part of each binding of `Worker.new({ bindings })` that is not in the config. |
| Durable Object classes | `new_sqlite_classes` in the migration, and `durable_objects.bindings` with the `class_name` of `Object.namespace` | The platform needs SQLite-backed classes (`MODULES.md` 7). `sync` checks both. |
| `triggers.crons` | The expressions of `Worker.cron` | `sync` checks them. A cron of the config with no `Worker.cron` needs a `scheduled!`. |

5. Run and deploy:

```sh
wrangler dev --local
wrangler deploy
```

## Build from source

```sh
ZIG=<zig 0.17> bench/build.sh      # the hosts, the glue, the test apps
ZIG=<zig 0.17> WORKERD=<workerd> bench/test-all.sh
ZIG=<zig 0.17> scripts/bundle.sh 0.1.0-rc.1   # dist/: the bundle and the shim package
scripts/test_bundle.sh                        # the examples against dist/, in wrangler
```

## Make a release

The steps, and what the first release needs, are in `PLAN.md` ("Status of steps 11a, 11b"). The release notes template is `.github/release-notes.md`.

## License

UPL-1.0, see `LICENSE`.
