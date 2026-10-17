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
| `<hash>.tar.zst` | The platform bundle. It goes in the header of the app. It has the Roc modules, `LICENSE` and the production host `targets/wasm32/host.wasm`. The packages `http` (roc-lang/http 2.0.0) and `cbor` (roc-cbor 0.1.0) stay URLs in the platform header: Roc downloads them. |
| `roc-cloudflare-workers-X.Y.Z.tgz` | The JS shim, as an npm package (`makeHandler`, `objectClass`, `entrypointClass`). `npm install <file or URL>` takes it. |

The release notes have both URLs. The package is not on the npm registry: the version of the shim must be the version of the platform, so the shim comes from the same release.

Needs: a Roc nightly (the release notes name it, `compat/last-stack-first-nightly` is the one that the release was built with), Node and `wrangler` (the tests use Node 26 and Wrangler 4).

## Use it

1. The app (`examples/hello/app.roc`). The header has the platform and nothing else. The platform brings `Http`, `Cbor` and the types of `roc-lang/http`: the app has no `http` and no `cbor` entry.

```roc
app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/X.Y.Z/<hash>.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "hello from Roc"))

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
```

| What the app writes | Meaning |
| --- | --- |
| `app [event!]` | The one function that takes every event (`API.md` 10.1). |
| `Worker.{ fetch!, scheduled!, queue!, ... }` | A record with the handlers that the app has. `worker.event!` sends each event to its handler. A kind with no handler is `Unhandled`. |
| `import pf.D1`, `pf.R2`, `pf.Kv`, ... | The modules of `MODULES.md`. A binding is `D1.binding("DB")`: the name is the name in the Wrangler config. |
| `import pf.Cbor` | Typed data as CBOR. It wraps roc-cbor, so no `cbor` entry. An app may add the same roc-cbor URL: the types are the same. |

2. Build the app. `--no-cache` is needed: a warm build cache gave other code in the same build (`PLAN.md` "Status of steps 11a, 11b").

```sh
roc build --target=wasm32 --no-cache --output=app.wasm app.roc
```

3. The shim. `npm install https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/X.Y.Z/roc-cloudflare-workers-X.Y.Z.tgz`. The entry of the Worker (`examples/hello/worker.js`):

```js
import app from './app.wasm';
import { makeHandler } from 'roc-cloudflare-workers';

export default makeHandler(app);
```

`makeHandler(module, opts)` throws at load for a bad option or a module that is not stack-first. The options are in `js/options.js`. A Durable Object class or a named entry point of the app is one export line before the default export (`objectClass("Room")`, `entrypointClass("Admin")`, `API.md` AQ10).

4. The Wrangler config (`examples/hello/wrangler.toml`):

| Setting | Value | Why |
| --- | --- | --- |
| `main` | The `worker.js` of step 3 | Wrangler compiles the `app.wasm` import itself. |
| `compatibility_date` | `2026-10-01` or newer | The date of the tests (`conformance/run.mjs`). |
| `compatibility_flags` | `["enable_request_signal"]` | Without it `request.signal` never fires: a task does not stop when the client goes away (`API.md` 10.2). |
| Bindings | Names that the app uses in `X.binding("NAME")` | One binding for each name. |
| Durable Object classes | `new_sqlite_classes` in the migration | The platform needs SQLite-backed classes (`MODULES.md` 7). |

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
