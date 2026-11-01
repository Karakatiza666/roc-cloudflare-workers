# cloudflare-workers

A Roc platform for Cloudflare Workers. The app compiles to a wasm32 reactor. The host is in Zig. Effects (fetch, D1, R2, KV, Cache API, Durable Object SQL) are direct-style hosted functions that wait on JS promises through JSPI.

Status: phases A and B are built (`PLAN.md`). The release files are made by `scripts/bundle.sh` and published by `.github/workflows/release.yml` (`PLAN.md` 11). The latest release is 0.0.2: see "Changes in 0.0.2".

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

0.0.2 has 5 changes that can break an app of 0.0.1 (the first 4 rows and the WebSocket row), one change that only removes an error (row 5), and a note about the Roc nightly 2026-10-26 (the last row). The rest of the changes since 0.0.1 are in CI and in test scripts (`ci.yml`, `scripts/test_bundle.sh`). They do not change the platform.

| Change | In 0.0.1 | In 0.0.2 | What the app author does |
| --- | --- | --- | --- |
| The type `R2.Range` is `R2.ByteRange` | `R2.Range` shadows a builtin type of Roc nightly 2026-10-26 and later. `roc build` prints a warning and exits with code 2, so `tln run build` stops. | `R2.ByteRange`. The values are the same: `From({ offset_bytes, length_bytes })` and `Suffix(n)`. | Write `R2.ByteRange` where the app names the type (`{ range ?: R2.ByteRange }`). An app that only writes the values changes nothing. |
| SQL rows: NULL and `Bool` (roc-cbor 0.2.2) | A NULL read only into a `Try(a, [Null])` field. A `Bool` field was `BadData`. | In a record, a NULL is the same as no key. An optional field `x ?: a` is absent. A `x : Try(a, [Missing])` field is `Err(Missing)`. A required field, also `x : Try(a, [Null])`, is `BadData("column x: missing or NULL, read a nullable column into x ?: a or Try(a, [Missing])")`. A `Bool` field reads 0 and 1. In a tuple (`all_tuples!`) a NULL still reads only into a `Try(a, [Null])` item. | Read a nullable column into `x ?: a` or `x : Try(a, [Missing])`. A `Bool` field now reads a boolean column. Code that matched the old `BadData` texts changes. |
| A record that crosses as CBOR has no `Try(a, [Null])` field | `Err(Null)` and `Sql.null` in a record field wrote `null`, and a `Try(a, [Null])` field read it back. | The writer writes no key for them. A `Try(a, [Null])` field reads back as `MissingRequiredField`. | In an RPC argument or reply, a queue message, a cell, a `Memo` value or an attachment, use `x ?: a` or `x : Try(a, [Missing])` for a field that can be empty. A list item, a tuple item, a `Dict` value and the root keep `Err(Null)`. No type of the platform has such a field. |
| `Memo` has no error type: the loader is an argument of `get!` | `Memo(a, e)`. `Memo.new(name, { max_age_ms, load! })`, then `memo.get!()`. On Roc nightly 2026-10-21 and later, a `Memo` constant that another module uses (or that two uses join with other `Infra(...)` errors) is a type mismatch at `?`, so the `Memo` had to be a function. | `Memo(a)`. `Memo.new(name, { max_age_ms })`, then `memo.get!(load!)`: `get! : Memo(a), (() => Try(a, e)) => Try(a, e)`. The error type comes from the loader at each call, so a `Memo` constant works in each module. The cache is the same: the pin of the name, `max_age_ms`, `clear!`. | Remove `load!` from `Memo.new`, give it to each `get!`, and write `Memo(a)` in place of `Memo(a, e)`. A `Memo` that was a function (`config = \|\| Memo.new(...)`) can be a constant again. Give the same loader at each call of one `Memo` (`MODULES.md` 9). |
| `Kv.get_with!` raises a `cache_ttl_ms` under 30 s to 30 s | A `cache_ttl_ms` under 30,000 was `Err(Infra(KvErr(..)))` (KV refuses a `cacheTtl` under 30 s). | The platform raises it to 30,000, so the read is `Ok`. The same for `get_with_metadata_with!` and the `Io` twins. This is the rule of `put_with!`, which raises a `ttl_ms` under 60 s to 60 s. | Nothing. Code that matched that `KvErr` can drop the match (`MODULES.md` 5.2). |
| WebSockets: errors of `send!` and `close!`, who closed, subprotocols, a bounded receive queue (`MODULES.md` 12) | `send!` gave `Closed` for each throw. `close!` gave `{}` and dropped a throw. `WebSocket.Closed` was `{ code, reason, clean }`. A client could not read the subprotocol of the server, and a server could not pick one. The receive queue of a socket had no limit. A `receive!` after `close!` could give `Closed` with 1006 "Network connection lost." for a clean close (an `error` event of workerd was the close record). | `send!` of `WebSocket` and `Object.Socket`: `Try({}, [Closed, Infra([SocketErr(Thrown)])])` (`Closed` for a closing or closed socket). `close!`: `Try({}, [BadCode, TooLarge])`. `Closed` has `by : [Peer, Us, Transport]`. New: `WebSocket.accept_with!` (`protocols`, `max_queued_bytes`), `protocol`, `protocols`, `pick_protocol`, `default_max_queued_bytes`, `closed!` (the close record with no message taken), `extensions` (the `Sec-WebSocket-Extensions` of a client, `NotReported` for a server); `connect_with!` takes `max_queued_bytes`; `Object.Self.accept_with!` takes `protocols`. A message that comes while the queue holds 4 MiB or more closes the socket with 1008. A clean close gives its own code (`MODULES.md` 12.2, "The `error` event"). | Write `_ = socket.close!(...)` (or handle the `Try`) where `close!` was a statement. A match on the error of `send!` adds the `Infra` arm. A record pattern on a `WebSocket.Closed` names `by` (or `..`). An app that reads slowly from a fast peer sets `max_queued_bytes`. |
| Roc nightly 2026-10-26 and later | The platform gave a warning (exit code 2). | `roc check` and `roc build` of the platform and the examples give 0 errors and 0 warnings. The nightlies 2026-10-19, 2026-10-26 and 2026-10-27 work too. `compat/last-stack-first-nightly` pins 2026-10-31 (f7bef6b), the nightly of the release build. From nightly 2026-10-28, the compiler adds 3 exports to each wasm module (`__stack_pointer`, `__stack_low`, `__stack_high`) and a maximum memory of 4 GiB minus the stack (65,520 pages). The platform does not use the 3 exports: the host owns the stack pointer. | A top-level `Io` value that another module joins with other `Infra(...)` errors is a type mismatch at `?` on 10-21 and later: write it as a function (`MODULES.md` 9). A `Memo` has no such problem in 0.0.2 (the row above). |

The platform header has roc-cbor 0.2.2: an app that adds the roc-cbor URL too uses the same URL (`examples/hello/with_cbor.roc`).

The module names do not change. `MODULES.md` 1, "Modules", now marks the low-level modules (`Cbor`, `Native`, `Io`, `Js`): an app needs only `Cbor`, `Native` and the `Io` functions `run!`, `both!`, `all!`, `race!`, `timeout`. `Io.new` and `Io.sync` (for a binding author) stay in `Io`: they cannot move to `Js` (Roc refuses the import cycle).

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

A project has three files: `main.roc`, `worker.js`, `wrangler.toml`. A fourth, `talon.toml`, holds the scripts and the pin of the helper `roc-cfw`. The shim is a copy of `js/` of the platform bundle in `.roc-cfw/` (gitignored). `roc-cfw sync` makes the copy and runs the command `sync` of the shim, which writes `worker.js`.

| Program | Version that was checked (2026-10-27) | Note |
| --- | --- | --- |
| Talon (`tln`) | 0.0.1 | `install.sh` of the release |
| Platform | 0.0.1 | `tln init` selects the newest release |
| `roc-cfw` | 0.0.1 (`Karakatiza666/roc-cloudflare-workers-cli`) | Pinned in `talon.toml` `[tools]` of each project. No global install |
| Node | 26 (JSPI) | `sync` runs the app in Node to read its manifest |
| Wrangler | 4.151.0 | Installed on the machine, not a project file |

The steps, with the output of a real run (`research/talon-fit/trial-0.0.1/`):

```text
$ mkdir hello && cd hello
$ tln init --platform Karakatiza666/roc-cloudflare-workers
check: passed
build: passed
.../hello/main.roc
  + roc: nightly-2026-10-27-de79a0f
created main.roc                       # the platform URL, the roc: pin, a stub body
created .github/workflows/ci.yml

$ tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw
building Karakatiza666/roc-cloudflare-workers-cli 0.0.1 with nightly-2026-10-14-38a3029
added tool roc-cfw 0.0.1 (Karakatiza666/roc-cloudflare-workers-cli)
.../hello/talon.toml: tools.roc-cfw = { ref = "Karakatiza666/roc-cloudflare-workers-cli@^0.0.1", url = "https://github.com/.../0.0.1/9fJGynVVjWajYb1sgwTGs7bFLRxB75VHuxMxnGu75UU8.tar.zst" }

$ tln x roc-cfw -- init
roc-cfw: wrote main.roc, ./wrangler.toml (name hello), ./talon.toml, ./.gitignore
roc-cfw: next: tln run build

$ tln run build                        # with platform 0.0.1: exit 2 after the build, see the note
0 errors and 1 warning found in 5.7s while successfully building:
    app.wasm

$ tln x roc-cfw -- sync                # the second step of build
roc-cfw: copied .../roc/packages/GcDNxAwPR5tSzqU8T2Kdj35CK3sQMRQDB8ywwfZKdrm/js to .roc-cfw
worker.js: written (0 object classes, 0 entry points)
wrangler.toml:
  ok      main = "worker.js"
  ok      compatibility_date = "2026-10-01"
  ok      compatibility_flags has enable_request_signal
  ok      compatibility_flags has global_fetch_strictly_public
  ok      [[d1_databases]] DB (d1)

$ wrangler dev --local                 # tln run dev runs build first, so it stops as build does
$ curl http://127.0.0.1:8787/
hello from Roc
```

| Step | Writes |
| --- | --- |
| `tln init --platform ...` | `main.roc`: the platform URL, the pin `roc: "<nightly>"` (the newest nightly that passes the check and the build), the body `event! = \|_\| crash "write the app"`. Also `.github/workflows/ci.yml` |
| `tln add --tool ... --as roc-cfw` | `talon.toml` `[tools] roc-cfw`: the range (`ref`) and the locked release URL (`url`). Talon builds the tool with its own nightly. `--as roc-cfw` sets the key that the template scripts use (the default key is the repository name) |
| `tln x roc-cfw -- init` | The template of the platform (`js/template/` of the bundle): the app body in `main.roc` (the header stays), `wrangler.toml` with the directory name, `[scripts]` in `talon.toml` (`[tools]` stays), `.gitignore` (`app.wasm`, `.roc-cfw/`, `.wrangler/`) |
| `tln run build` | `roc build --target=wasm32 --no-cache --output=app.wasm main.roc`, then `roc-cfw sync`: `.roc-cfw/`, `worker.js` |

The scripts that `init` writes:

| Script | Steps |
| --- | --- |
| `build` | `roc build ... main.roc`, `roc-cfw sync` |
| `check` | `roc build ... main.roc`, `roc-cfw sync --check` (for CI: writes nothing) |
| `dev` | `@build`, `wrangler dev --local` |
| `deploy` | `@check`, `wrangler deploy` (first `wrangler d1 create <name>` and the id in `wrangler.toml`) |

The commands of `roc-cfw` (run them with `tln x roc-cfw -- <command>`, or as a step of `[scripts]`, where the key `roc-cfw` is the project pin):

| Command | What it does |
| --- | --- |
| `roc-cfw shim [--file main.roc]` | Finds `js/` of the platform of the app (`tln path pf`), checks `js/cfw.json` (`api` 1), and copies `js/` to `.roc-cfw/` when the platform hash changed (stamp `.roc-cfw/.platform`). Runs no node |
| `roc-cfw sync [--file main.roc] [sync args]` | `shim`, then `node .roc-cfw/cli.mjs sync --file <app> [sync args]` (the table below). The exit code is the exit code of `sync` |
| `roc-cfw init [--name <name>]` | Writes the template (the table above). It replaces only a stub body and never writes over a `wrangler.toml` |
| `roc-cfw help` | The usage |

Gaps of the released versions (2026-10-27):

| Gap | Cause | What to do today | Fixed by |
| --- | --- | --- | --- |
| `tln run build` (and `dev`, `check`, `deploy`) stops after the `roc build` step with exit 2. `app.wasm` is written | Platform 0.0.1: the type `R2.Range` shadows a builtin type. `roc build` gives exit 2 for a warning, with each nightly. Talon 0.0.1 has no `ok-exit` for a step | Run the next step by hand: `tln x roc-cfw -- sync` (or `sync --check`), then `wrangler dev --local` | Platform 0.0.2 (`R2.ByteRange`). `tln init` selects it when it is 2 days old (from 2026-11-03), or now with `tln init --platform Karakatiza666/roc-cloudflare-workers@0.0.2` on a Talon after 0.0.1. Talon after 0.0.1 also has `ok-exit = [2]` for a step (Talon R-RUN18) |
| `tln init --platform` gives `no release of Karakatiza666/roc-cloudflare-workers is old enough for min-release-age`, and `tln add --tool` finds no release of the helper | `min-release-age` is 2 days. Platform 0.0.1 is from 2026-10-26 20:41 UTC, `roc-cfw` 0.0.1 from 2026-10-27 07:52 UTC. Talon 0.0.1 has no `@<version>` for `init --platform` and no `min-release-age-exclude` | Wait for the age, or set `min-release-age = "0d"` in the Talon `config.toml` for this one setup | Time (the platform from 2026-10-28 20:41 UTC, the helper from 2026-10-29 07:52 UTC) |

Update of the platform: `tln update pf` (a new URL in `main.roc`), then `tln run build`. `roc-cfw sync` sees a new hash and copies the new `js/`. The shim and the host must come from the same release. `tln update roc-cfw` moves the helper inside its range.

The manual way, with no helper (a fallback):

```sh
# main.roc with the release URL (tln init --platform ...), wrangler.toml and .gitignore from js/template/ of the bundle
cp -r "$(tln path pf)/js" .roc-cfw    # tln path pf: the directory of the platform in the package cache
roc build --target=wasm32 --no-cache --output=app.wasm main.roc
node .roc-cfw/cli.mjs sync           # writes worker.js, checks wrangler.toml
wrangler dev --local
```

For an update, copy `js/` of the new bundle to `.roc-cfw/` again and run `sync`. Here `roc` is the proxy that `tln setup` installs.

The command `sync` of the shim (`roc-cfw sync` runs it):

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
