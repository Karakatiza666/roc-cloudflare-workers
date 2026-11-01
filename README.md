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

There is no npm package and no `package.json` in a project. The release notes have the URL. The URL of the latest release:

| Release | URL for the app header | Built with |
| --- | --- | --- |
| 0.0.2 | `https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/f352LLRKJCZ4JJVEocp3H9e4e6Sxa6Ym5CxZ1GZCpfd.tar.zst` | `nightly-2026-10-31-f7bef6b` |

Use the release URL. `dist/` of this repository is a local build of `scripts/bundle.sh` (gitignored). Its hash is not the hash of the release, so do not take a URL or a file from `dist/`.

## Changes after 0.0.2 (not released)

| Change | In 0.0.2 | After 0.0.2 | What the app author does |
| --- | --- | --- | --- |
| One clock: the `makeHandler` option `now` | `now` drove only the task deadlines, `graceMs` and the pin expiry (`Memo`, `Js.pin!`). `Time.now_ms!`, `Io.timeout_at` and `set_alarm_in!` read `Date.now()`. A test had to set `Date.now` and `now` both. | `now` (default `Date.now`) drives `Time.now_ms!`, `Memo` and pin expiry, the task deadlines, `graceMs`, `Io.timeout_at` and `Object.Self.set_alarm_in!`. Timers stay real: `Time.sleep`, `Io.timeout` and the deadline timer wait real ms. A cron `time_ms` comes from the event (`MODULES.md` 11, "The clock"). | Nothing in production (`now` unset is `Date.now`). A test sets only `now`, and can remove an override of `Date.now`. |
| A minimum nightly: `min_nightly` in `js/cfw.json`, checked by `sync` | No supported range. The README named some nightlies that work. | `js/cfw.json` is `{ "api": 1, "min_nightly": "nightly-2026-10-19-601b54c" }`. `sync` prints a block `Roc nightly (app.wasm):`. A wasm with the stack exports of 2026-10-28 and later is `ok`. Else the `roc:` pin of the app header: older than `min_nightly` is `warn` (exit 0, exit 1 with `--check`). No pin: a `note` ("Supported nightlies"). | Build with a nightly from the table "Supported nightlies". A CI step `sync --check` fails for a `roc:` pin older than 2026-10-19: move the pin (`tln upgrade roc`). `roc-cfw` 0.0.1 reads only `api` of `cfw.json`, so it works with the new key. |
| Docs: the release URL, limits, tests (`README.md` "What a release has", "Limits and known behavior", "Testing an app"; `MODULES.md` 1, 5.1, 11; `API.md` 10.1; `js/template/talon.toml`) | The README had no literal release URL. The window limit of `ZstdStream` (8 MiB), the 30 s after the response, tar, and the facts of workerd, local D1 and Node for tests were not in the docs, or only in a doc comment. | The 0.0.2 URL and the note that `dist/` is a local build with another hash. The limits table. roc-tar 0.0.1 for tar. The `ok-exit = [2]` form of Talon after 0.0.1 for a build with warnings (a comment in the template). | Take the platform URL from the release, never from `dist/`. |
| Repeated query parameters: `Request.query_all`, `Request.query_pairs` | Only `query`: the first value of a name. A route with `?short=a&short=b` parsed the URL itself. `query` kept an empty part (`&&`) as a pair, gave the raw text for invalid UTF-8 (`%FF`), and started the query at a `?` after the `#`. | `query_all : Request, Str -> List(Str)` (each value, in order) and `query_pairs : Request -> List((Str, Str))` (each pair, in order). All three parse as `URLSearchParams` (application/x-www-form-urlencoded, WHATWG URL): an empty part is skipped, invalid UTF-8 is U+FFFD, the query ends at the first `#`. `query` is the first value of `query_all` (`MODULES.md` 4, "Query parameters"). | Replace a parse of the URL with `req.query_all(name)`. An app that reads `query` changes nothing, unless it read an empty name or invalid UTF-8. |
| `Body.chunk!` fills a chunk to 64 KiB; `Body.chunk_with!` | `chunk!` gave each part of the JS stream: about 4 KiB in workerd, so 28,766 crossings for 110 MB. | `chunk!` adds the next parts that are ready (they complete before a timer of 0 ms) to 64 KiB (`Body.default_fill`). The first part is the only wait, so a slow stream still gives each part when it comes. `chunk_with!(body, { fill_bytes ?: U64, max_bytes ?: U64 })` sets the target and the limit. 110 MB of a Miniflare `fetch` body: 1,760 crossings and 392 ms, it was 28,161 and 1,472 ms (`MODULES.md` 4, "Chunks"). `pass_through!`, `Body.writer!` and WebSocket do not change. | Nothing. Code that needs each part at once (a proxy that writes each part on) uses `chunk_with!(body, { fill_bytes: 1 })`. Code that counted on chunks of about 4 KiB gets larger chunks (at most `default_max`). |
| Docs: `Worker.new({ fetch! })` with one handler | Only a short note in `MODULES.md` 3. | `MODULES.md` 2 shows the error text ("This argument has the type: `Request => Try(Response, _a)`") and the fix `Worker.new({ fetch!: fetch! })`. `{ fetch! }` with one name is a block in Roc, not a record: a language rule, no platform change. | Write `{ fetch!: fetch! }` (or `{ fetch!, }`). |

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

Needs: a Roc nightly (see "Supported nightlies"), Node (JSPI: the tests use Node 26) and `wrangler` (the tests use Wrangler 4). Install Wrangler on the machine (see the Cloudflare documentation). It is a program, not a file of a project.

### Supported nightlies

Supported nightlies: `nightly-2026-10-19-601b54c` (the `min_nightly` of `js/cfw.json`) to `nightly-2026-10-31-f7bef6b` (the release build, `compat/last-stack-first-nightly`). A later nightly is not checked before a release: the scheduled job `nightly-layout` builds and tests each new one. Checked 2026-11-02 against the platform after 0.0.2 (`research/min-nightly/`): the conformance app (489 checks in Miniflare), `bench/node-test.mjs` and `bench/handler-test.mjs` with the hosts of the release nightly.

| Nightly | Result |
| --- | --- |
| 2026-10-31 (f7bef6b) | The release build. All tests pass |
| 2026-10-27 (de79a0f), 2026-10-21 (5349569), 2026-10-19 (601b54c) | Pass. The wasm has no `__stack_pointer`, `__stack_low` and `__stack_high` exports (the compiler adds them from 2026-10-28). The platform does not use them, so only `bench/exports-test.mjs` sees the difference |
| 2026-10-18 (1df370f), 2026-10-14 (38a3029) | Not supported: the compiler crashes (SIGSEGV in `monotype`) on the conformance app. A small app can build, but a larger one can crash the compiler |
| 2026-10-09 and older | Not supported: the module is not stack-first, and the shim refuses it |

`sync` checks the nightly (`MODULES.md` 3, "`sync`, the Roc nightly"). The wasm file does not record the compiler version. A wasm with the stack exports is from 2026-10-28 or later, so it is new enough. For an older wasm, the `roc:` pin of the app header decides: a pin older than `min_nightly` is a warning (exit 0, and exit 1 with `--check`). With no pin, `sync` prints a note.

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
| `node .roc-cfw/cli.mjs sync` | Reads the manifest of `app.wasm`, writes `worker.js` (one export line for each class, then `makeHandler`), and checks `wrangler.toml`: `main`, the compatibility date and flags, `durable_objects.bindings`, `migrations` (`new_sqlite_classes`), the bindings of `Worker.new({ bindings })`, `triggers.crons` of `Worker.new({ crons })`. It also checks the link to the other Workers of the same repo: a service binding or a `namespace_remote` goes to a Worker by its name in the Wrangler config, so `sync` finds that Worker (its config and its built wasm) and compares the interface names (`Rpc.iface("Ledger")`). It also checks the Roc nightly of the app against `min_nightly` of `cfw.json` ("Supported nightlies"). It prints the parts to add and gives exit 1 when one is missing or wrong. `--check`: write nothing (for CI). |

The steps below say what each file has.

1. The app (`examples/hello/main.roc`). The header has the platform and nothing else. Put the release URL in place of `X.Y.Z/<hash>` (for 0.0.2, the URL in "What a release has"). The platform brings `Http`, `Cbor` and the types of `roc-lang/http`: the app has no `http` and no `cbor` entry.

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

Use the default build mode (`--opt=speed`) or `--opt=size`. Do not use `--opt=dev`: on nightly 2026-10-31 its wasm32 code reads a `U8`, `U16`, `I8` or `I16`, and a BLOB into `List(U8)` or `Cbor.Bytes`, as `BadData` (a compiler bug of the `I128` conversions, `research/blob-002/README.md`). The platform is tested with `speed` only.

A `roc build` with warnings and no errors exits with 2, and it still writes the `.wasm` file. In a Talon script (Talon after 0.0.1), accept it on the build step: `{ run = "roc build --target=wasm32 --no-cache --output=app.wasm main.roc", ok-exit = [2] }` (Talon R-RUN18). Talon 0.0.1 has no `ok-exit`: there, the step stops the script (see "Gaps of the released versions").

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

## Limits and known behavior

| Item | Value or behavior | Where |
| --- | --- | --- |
| Work after the response (`Response.after`) | 30 s after the response body is complete (the shim option `afterRespondMs`, the `waitUntil` limit of Workers). `Ctx` has no such function: use `res.after(work!)` | `MODULES.md` 11, `API.md` 10.2 |
| Window of a `Native.ZstdStream` | 8 MiB, a hard limit. A larger window is `WindowTooLarge`. `zstd_decode!` has no window limit | `MODULES.md` 1 ("`Native` in short"), `API.md` 8 |
| tar | Not in `Native`. Use roc-tar 0.0.1 (`https://github.com/Karakatiza666/roc-tar/releases/download/0.0.1/FGAUE1Pds7Fvd48GkrAYd9rRUpztew8bgUZjUrKPGyo7.tar.zst`), a streaming ustar, pax and GNU reader in pure Roc that takes the output of `Native.ZstdStream` | `MODULES.md` 1 |
| An HTTP method that workerd does not know (`BREW`) | `501 ERROR: Unrecognized request method.` from workerd. The Worker does not run | `API.md` 10.1 |
| A D1 bookmark in local D1 | Local D1 takes any bookmark text in `with_session!(After(b))`. A local test cannot check a bookmark | `MODULES.md` 5.1 |
| `.wrangler/` directories | `wrangler dev`, `wrangler d1 execute --local` and `getPlatformProxy` write local state in `.wrangler/` next to the Wrangler config, also when you run them from another directory (for example a test harness in `tests/` that names `../wrangler.toml`). A harness in a directory with its own config makes its own `.wrangler/` there. The template `.gitignore` has the line `.wrangler/`, which matches a `.wrangler/` directory at each depth. Delete these directories for a clean test: they hold the local D1, KV and R2 data | |

## Testing an app

There is no test helper in the release yet. A test runs the app in Miniflare (`conformance/run.mjs` shows the options). Two facts of Node and Miniflare change what a request has:

| Fact | What to do |
| --- | --- |
| `dispatchFetch` with a string body adds `Content-Type: text/plain;charset=UTF-8` | For a request with no `Content-Type`, send the body as bytes (`Buffer.from(text)`) |
| Node `fetch` (undici, also under `dispatchFetch`) adds `Cache-Control: no-cache` and `Pragma: no-cache` to a request that has `If-None-Match` (the fetch cache mode `default`) | Give `cache: 'force-cache'` in the request init. Then a header is sent only when the test sets it |

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
