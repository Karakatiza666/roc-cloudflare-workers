# cloudflare-workers

A Roc platform for Cloudflare Workers. The app compiles to a wasm32 reactor. The host is in Zig. Effects (fetch, D1, R2, KV, Cache API, Durable Object SQL) are direct-style hosted functions that wait on JS promises through JSPI.

Status: phases A and B are built (`PLAN.md`). The release files are made by `scripts/bundle.sh` and published by `.github/workflows/release.yml` (`PLAN.md` 11). The latest release is 0.0.1. This branch is 0.0.2 (not released yet): see "Changes in 0.0.2".

| Document | Content |
| --- | --- |
| `API.md` | The app API: events, `Js` values, programs, the contract |
| `MODULES.md` | Each platform module: what it does, its errors, its limits |
| `PLAN.md` | The build plan, the status of each step, the measurements |
| `examples/hello/` | A Worker project that uses a release |
| `talon.toml` | The scripts of the examples (`tln run hello`) |

## What a release has

Each release (tag `X.Y.Z`) has 1 file. The platform and the shim have the same version, because they are in the same file.

| File | Use |
| --- | --- |
| `<hash>.tar.zst` | The platform bundle. It goes in the header of the app. It has the Roc modules, `LICENSE`, the production host `targets/wasm32/host.wasm`, and the JS shim in `js/` (`index.js` and the other `*.js` files: `makeHandler`, `objectClass`, `entrypointClass`; `cli.mjs`: the command `sync`; `cfw.json`; `template/`). The packages `http` (roc-lang/http 2.0.0) and `cbor` (roc-cbor 0.2.2) stay URLs in the platform header: Roc downloads them. |

There is no npm package and no `package.json` in a project. The release notes have the URL.

## Changes in 0.0.2

0.0.2 has 3 changes that can break an app of 0.0.1 (the first 3 rows), and a note about the Roc nightly 2026-10-26 (the last row). The rest of the changes since 0.0.1 are in CI and in test scripts (`ci.yml`, `scripts/test_bundle.sh`). They do not change the platform.

| Change | In 0.0.1 | In 0.0.2 | What the app author does |
| --- | --- | --- | --- |
| The type `R2.Range` is `R2.ByteRange` | `R2.Range` shadows a builtin type of Roc nightly 2026-10-26 and later. `roc build` prints a warning and exits with code 2, so `tln run build` stops. | `R2.ByteRange`. The values are the same: `From({ offset_bytes, length_bytes })` and `Suffix(n)`. | Write `R2.ByteRange` where the app names the type (`{ range ?: R2.ByteRange }`). An app that only writes the values changes nothing. |
| SQL rows: NULL and `Bool` (roc-cbor 0.2.2) | A NULL read only into a `Try(a, [Null])` field. A `Bool` field was `BadData`. | In a record, a NULL is the same as no key. An optional field `x ?: a` is absent. A `x : Try(a, [Missing])` field is `Err(Missing)`. A required field, also `x : Try(a, [Null])`, is `BadData("column x: missing or NULL, read a nullable column into x ?: a or Try(a, [Missing])")`. A `Bool` field reads 0 and 1. In a tuple (`all_tuples!`) a NULL still reads only into a `Try(a, [Null])` item. | Read a nullable column into `x ?: a` or `x : Try(a, [Missing])`. A `Bool` field now reads a boolean column. Code that matched the old `BadData` texts changes. |
| A record that crosses as CBOR has no `Try(a, [Null])` field | `Err(Null)` and `Sql.null` in a record field wrote `null`, and a `Try(a, [Null])` field read it back. | The writer writes no key for them. A `Try(a, [Null])` field reads back as `MissingRequiredField`. | In an RPC argument or reply, a queue message, a cell, a `Memo` value or an attachment, use `x ?: a` or `x : Try(a, [Missing])` for a field that can be empty. A list item, a tuple item, a `Dict` value and the root keep `Err(Null)`. No type of the platform has such a field. |
| Roc nightly 2026-10-26 | The platform gave a warning (exit code 2). | `roc check` and `roc build` of the platform and the examples give 0 errors and 0 warnings. The pinned nightly (2026-10-19, `compat/last-stack-first-nightly`) works too. | A `Memo` constant that `?` joins with other `Infra(...)` errors can be a type mismatch on 10-26. Write the `Memo` as a function (`MODULES.md` 9). |

The platform header has roc-cbor 0.2.2: an app that adds the roc-cbor URL too uses the same URL (`examples/hello/with_cbor.roc`).

Needs: a Roc nightly (the release notes name it, `compat/last-stack-first-nightly` is the one that the release was built with), Node (JSPI: the tests use Node 26) and `wrangler` (the tests use Wrangler 4). Install Wrangler on the machine (see the Cloudflare documentation). It is a program, not a file of a project.

## Use it in this repository

The root `talon.toml` has the scripts of the examples. They need Talon (`tln`), the Roc nightly of `compat/last-stack-first-nightly` (`tln roc install <name>`), and Node.

| Command | What it does |
| --- | --- |
| `tln run hello` | `roc build` of `examples/hello/main.roc`, then `node js/cli.mjs sync` (it writes `examples/hello/worker.js` and checks `wrangler.toml`) |
| `tln run auction` | `roc build` of `web.roc` and `ledger.roc`, then `sync` of each Worker |
| `tln run examples` | Both |

The scripts run from the root: a build inside `examples/auction/` gives `PathOutsideWorkspace`. The `worker.js` files of the examples import `../../js/index.js`: the relative path from the entry file to `js/`, where `sync` runs from. `git diff --exit-code examples/` after `tln run examples` must be empty.

## Use it in your project

A project has three files: `main.roc`, `worker.js`, `wrangler.toml`. A fourth, `talon.toml`, holds the scripts. The shim is a copy of `js/` of the platform bundle in `.roc-cfw/` (put `.roc-cfw/` in `.gitignore`). The command `sync` of the shim writes `worker.js`.

Planned setup, with the helper `roc-cfw` (`research/talon-fit/TRANSITION.md`; it has no release yet, so this does not work today):

```sh
tln init --platform Karakatiza666/roc-cloudflare-workers    # main.roc with the platform line
tln add --tool Karakatiza666/roc-cloudflare-workers-cli     # [tools] roc-cfw in talon.toml
tln x roc-cfw -- init                                       # app body, wrangler.toml, [scripts], .gitignore
tln run build                                               # roc build, then roc-cfw sync
tln run dev                                                 # wrangler dev --local
```

The manual way, which works today:

```sh
mkdir my-worker && cd my-worker
cp /path/to/this/repo/examples/hello/{main.roc,wrangler.toml} .   # or the files of js/template/ in the bundle
# 1. In main.roc, write the release URL in the platform line.
# 2. roc check main.roc downloads the bundle into the Roc package cache. Copy its js/ to .roc-cfw/:
cp -r ~/.cache/roc/packages/<hash>/js .roc-cfw    # <hash>: the file name in the URL, without .tar.zst. $XDG_CACHE_HOME/roc/packages/ when it is set
roc build --target=wasm32 --no-cache --output=app.wasm main.roc
node .roc-cfw/cli.mjs sync      # writes worker.js, checks wrangler.toml
wrangler dev --local
```

Update of the platform: write the new URL in `main.roc`, copy `js/` of the new bundle to `.roc-cfw/` again, and run `sync`. The shim and the host must come from the same release.

| Command | What it does |
| --- | --- |
| `node .roc-cfw/cli.mjs sync` | Reads the manifest of `app.wasm`, writes `worker.js` (one export line for each class, then `makeHandler`), and checks `wrangler.toml`: `main`, the compatibility date and flags, `durable_objects.bindings`, `migrations` (`new_sqlite_classes`), the bindings of `Worker.new({ bindings })`, `triggers.crons` of `Worker.new({ crons })`. It also checks the link to the other Workers of the same repo: a service binding or a `namespace_remote` goes to a Worker by its name in the Wrangler config, so `sync` finds that Worker (its config and its built wasm) and compares the interface names (`Rpc.iface("Ledger")`). It prints the parts to add and gives exit 1 when one is missing or wrong. `--check`: write nothing (for CI). |

The steps below say what each file has.

1. The app (`examples/hello/main.roc`). The header has the platform and nothing else. The platform brings `Http`, `Cbor` and the types of `roc-lang/http`: the app has no `http` and no `cbor` entry.

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
| `import pf.D1`, `pf.R2`, `pf.Kv`, ... | The modules of `MODULES.md`. A binding is `D1.binding("DB")`: the name is the name in the Wrangler config. A Durable Object namespace takes its class value: `Object.namespace("ROOMS", { class: room })`, with `room = Object.class("Room", ...)`. The namespace has the interface of the class, so `call!` takes the `Rpc` constants of that interface only (`Rpc(Room, ..)`, with `Room := []`). `Worker.new` takes `objects: [room.erase()]`. For a class of this Worker with no importable value (a module cycle): `Object.namespace_named("ROOMS", "Room", room_iface)`. For a class of another Worker: `Object.namespace_remote("FAR", { class: "Room", script: "other" }, room_iface)`. `room_iface : Rpc.Iface(Room)` is `Rpc.Iface.{}`. |
| `Worker.new({ ..., bindings: [db.declare(), rooms.declare()] })` | The bindings that the app uses, in the manifest (`MODULES.md` 3). The shim checks at load that `env` has each one with its kind, and `sync` checks the Wrangler config. Optional. |
| `Worker.new({ ..., crons: [Worker.cron("*/5 * * * *", settle!)] })` | A handler for each cron expression, in place of one `scheduled!` that matches `s.cron()`. `sync` checks `triggers.crons`. `scheduled!` stays: it gets the runs of the other crons. |
| `req.method()`, `req.url()`, `res.status()` | `Request`, `Response` and the payloads of the handlers are opaque: the app reads them with methods, and a field read does not compile (`MODULES.md` MC15). A function with no argument is `f!()` (MC14). |
| `import pf.Cbor` | Typed data as CBOR. It wraps roc-cbor, so no `cbor` entry. An app may add the same roc-cbor URL: the types are the same. |

2. Build the app. Use `--no-cache`, so that each build of the same source gives the same bytes: a build with a warm build cache gives other bytes than a clean build (`research/no-cache-repro/README.md`). No wrong behavior of a warm build is known (the conformance run passes on both), but a release and a test must build what a clean machine builds.

```sh
roc build --target=wasm32 --no-cache --output=app.wasm main.roc
```

A `roc build` with type errors still writes the `.wasm` file. It prints "N errors and 0 warnings found ... while successfully building" and exits with 1 (checked 2026-10-20 with one bad line). A build is good only when the exit code is 0 and the text is "0 errors and 0 warnings". A script must check the exit code. In the repo, run the command from the root (a build inside `examples/auction/` gives `PathOutsideWorkspace`).

3. The shim. It is `js/` of the platform bundle, copied to `.roc-cfw/` (see above). The entry of the Worker is the file that `sync` writes. The import is the relative path from the entry file to the directory of `cli.mjs` (`./.roc-cfw/index.js` in a project, `../../js/index.js` in `examples/hello/worker.js`):

```js
// Made by roc-cloudflare-workers sync from the manifest of the app. Run it again after a change of the classes in Roc.
import app from './app.wasm';
import { makeHandler } from './.roc-cfw/index.js';

export default makeHandler(app);
```

`makeHandler(module, opts)` throws at load for a bad option, a module that is not stack-first, a class with no export line, and a binding of `Worker.new({ bindings })` that is not in `env` with its kind. The options are in `js/options.js`. A Durable Object class or a named entry point of the app is one export line before the default export (`objectClass("Room")`, `entrypointClass("Admin")`, `API.md` AQ10): `sync` writes these lines. An app with options (`ops` and others) puts them in `worker.options.js` next to `worker.js`: its default export is the options object. `sync` then writes `import options from './worker.options.js';` and `makeHandler(app, options)`, and `sync --check` checks the import. `sync` never writes the options file (`MODULES.md` 3, "The options file"). `sync` also reads the app source (`--file`, default `<wasm name>.roc`, else `main.roc`) and warns of a handler that the app defines and `Worker.new` does not list (`sync --check` fails for it; `MODULES.md` 3).

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
| `services` and `durable_objects.bindings` with `script_name` | The Worker of the link: its `name` in its own Wrangler config, in the same repo | The types check one Worker. `sync` checks the link: the other Worker must be built (its `.wasm` file, the one that its `main` imports, or `app.wasm`), and its entry point or class must have the same interface name as the binding. A Worker that `sync` does not find or that is not built is a note (build it with `roc build`), not a failure. |

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
