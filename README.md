# cloudflare-workers

A Roc platform for Cloudflare Workers. The app compiles to a wasm32 reactor. The host is in Zig. Effects (fetch, D1, R2, KV, Cache API, Durable Object SQL) are direct-style hosted functions that wait on JS promises through JSPI.

Status: phases A and B are built (`PLAN.md`). The release files are made by `scripts/bundle.sh` and published by `.github/workflows/release.yml` (`PLAN.md` 11). The latest release is 0.0.6: see "Changes in 0.0.6".

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
| `<hash>.tar.zst` | The platform bundle. It goes in the header of the app. It has the Roc modules, `LICENSE`, the production host `targets/wasm32/host.wasm`, and the JS shim in `js/` (`index.js` and the other `*.js` files: `makeHandler`, `objectClass`, `entrypointClass`; `cli.mjs`: the command `sync`; `cfw.json`; `template/`). The packages `http` (roc-lang/http 2.0.0) and `cbor` (roc-cbor 0.2.3) stay URLs in the platform header: Roc downloads them. |

There is no npm package and no `package.json` in a project. The release notes have the URL. The URL of the latest release:

| Release | URL for the app header | Built with |
| --- | --- | --- |
| 0.0.5 | `https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.5/7cJKFdsThj1QcGDftbB9pJVyLNJuMx5SgWXyVf5Te48k.tar.zst` | `nightly-2026-11-01-48d3369` |
| 0.0.4 | `https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.4/AuZxUqJVSbVSbPX9EUhBGLVqgS3yZUE7ZC5VC2EqSeUk.tar.zst` | `nightly-2026-11-01-48d3369` |
| 0.0.3 | `https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.3/Bup7G6Xgk53Bot1YY9AKQP9e73JVGbWqUyqD24taUYRv.tar.zst` | `nightly-2026-10-31-f7bef6b` |
| 0.0.2 | `https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.2/f352LLRKJCZ4JJVEocp3H9e4e6Sxa6Ym5CxZ1GZCpfd.tar.zst` | `nightly-2026-10-31-f7bef6b` |

Use the release URL. `dist/` of this repository is a local build of `scripts/bundle.sh` (gitignored). Its hash is not the hash of the release, so do not take a URL or a file from `dist/`.

## Changes in 0.0.6

| Change | In 0.0.5 | In 0.0.6 | What the app author does |
| --- | --- | --- | --- |
| `startApp`: `delaySeconds` in `res.calls` and `app.calls()` | The record had it, but the grouped view dropped it (bug). | Each field of a call record is in `list`. | Nothing. |
| `app.now` | A value copied at the start (bug): it did not follow `setNow` or `advance`. | A getter: the clock of the isolate, or `null` for real time. | Nothing. |
| D1 seeds | One round trip for each statement. | One batch for each seed text (`reset()` is faster). A failed batch runs again one statement at a time, for the error. | Nothing. |
| Docs: queue consumers in a test | Not said. | "Testing an app", Bindings: with no `queues.consumers`, the Worker consumes its own sends; `consumers = []` stops that. | Add `consumers = []` to a test config that checks only `calls`. |

## Changes in 0.0.5

| Change | In 0.0.4 | In 0.0.5 | What the app author does |
| --- | --- | --- | --- |
| `startApp`: `delaySeconds` of a queue send in `calls` | A queue send record had the body and the content type, not the delay. | `delaySeconds` is kept when the call gives it: on a `send`, on each message of a `sendBatch`, and on the batch options. | A test can check the delay of a send. |

The Roc API and the ABI do not change.

## Changes in 0.0.4

| Change | In 0.0.3 | In 0.0.4 | What the app author does |
| --- | --- | --- | --- |
| `startApp`: a local form for rate limit bindings | A rate limit binding had no local form. `startApp` refused the app unless the test gave the binding in `services`, `bindings` or `hooks`. | Miniflare makes each declared rate limit binding. The limit comes from the option `ratelimits: { NAME: { limit, period } }`, else from `[[ratelimits]]` or `unsafe.bindings` in the config, else 100 in 60 s. `app.reset()` also clears the counters ("Testing an app"). | Remove a hooks module or a `services` entry that only made a fake rate limiter. |
| `startApp`: the body of a queue send in `calls` | A queue `send` or `sendBatch` call had no body. | A `send` call has `body` (`bytes`, `size`, the decoded `value`) and `contentType`. A `sendBatch` call has `bodies`. At most 4096 bytes are kept. | A test can check what a send carried. |
| Docs: the `Memo` expiry edge | Not in `MODULES.md` 9. | A value pinned at time t expires when the clock is t + `max_age_ms` or later (age >= max). | An app rule "older than max" (age > max) is 1 ms later than the `Memo`. |

The Roc API and the ABI do not change. An app built for 0.0.3 works with 0.0.4.

## Changes in 0.0.3

| Change | In 0.0.2 | In 0.0.3 | What the app author does |
| --- | --- | --- | --- |
| One clock: the `makeHandler` option `now` | `now` drove only the task deadlines, `graceMs` and the pin expiry (`Memo`, `Js.pin!`). `Time.now_ms!`, `Io.timeout_at` and `set_alarm_in!` read `Date.now()`. A test had to set `Date.now` and `now` both. | `now` (default `Date.now`) drives `Time.now_ms!`, `Memo` and pin expiry, the task deadlines, `graceMs`, `Io.timeout_at` and `Object.Self.set_alarm_in!`. Timers stay real: `Time.sleep`, `Io.timeout` and the deadline timer wait real ms. A cron `time_ms` comes from the event (`MODULES.md` 11, "The clock"). | Nothing in production (`now` unset is `Date.now`). A test sets only `now`, and can remove an override of `Date.now`. |
| A minimum nightly: `min_nightly` in `js/cfw.json`, checked by `sync` | No supported range. The README named some nightlies that work. | `js/cfw.json` is `{ "api": 1, "min_nightly": "nightly-2026-10-19-601b54c" }`. `sync` prints a block `Roc nightly (app.wasm):`. A wasm with the stack exports of 2026-10-28 and later is `ok`. Else the `roc:` pin of the app header: older than `min_nightly` is `warn` (exit 0, exit 1 with `--check`). No pin: a `note` ("Supported nightlies"). | Build with a nightly from the table "Supported nightlies". A CI step `sync --check` fails for a `roc:` pin older than 2026-10-19: move the pin (`tln upgrade roc`). `roc-cfw` 0.0.1 reads only `api` of `cfw.json`, so it works with the new key. |
| Docs: the release URL, limits, tests (`README.md` "What a release has", "Limits and known behavior", "Testing an app"; `MODULES.md` 1, 5.1, 11; `API.md` 10.1; `js/template/talon.toml`) | The README had no literal release URL. The window limit of `ZstdStream` (8 MiB), the 30 s after the response, tar, and the facts of workerd, local D1 and Node for tests were not in the docs, or only in a doc comment. | The 0.0.2 URL and the note that `dist/` is a local build with another hash. The limits table. roc-tar 0.0.1 for tar. The `ok-exit = [2]` form of Talon after 0.0.1 for a build with warnings (a comment in the template). | Take the platform URL from the release, never from `dist/`. |
| Fixed responses of a trap: `Worker.new({ on_trap })` | A trap of `fetch` gave `trap <error>` as `text/plain` (500, or 503 for OOM, a shed, a cancel), and `Err` gave 500 with no body. The app could not give its own form (for example `application/problem+json`), and the wasm error text went to each client. No 503 had `retry-after`. | `on_trap : Worker.OnTrap` gives a fixed response (`Worker.Fixed`: status 400 to 599, headers, body) for each cause (`crashed`, `alarm`, `cpu`, `oom`, `shed`, `deadline`, `cancelled`, `event`, `failed`), with a required `default`. It is in the manifest; `makeHandler` checks it at load (at most 16 headers, a value of 1,024 bytes, a body of 4,096 bytes, no `content-length` or `set-cookie`). The shim sends a new copy with no Roc code. It applies to the `fetch` of the Worker, of an object class and of a named entry point. `sync` prints it. A 503 of a shed or OOM now has `retry-after: 1` (`ceil(graceMs / 1000)`), also with no `on_trap`. The status and the body of each other response do not change (`MODULES.md` 3, `API.md` 10.3). | Nothing. To answer in your own form, add `on_trap: { default: ..., ... }` as a literal in the call of `Worker.new`. A client that reads `retry-after` waits 1 s after a shed or OOM. |
| Repeated query parameters: `Request.query_all`, `Request.query_pairs` | Only `query`: the first value of a name. A route with `?short=a&short=b` parsed the URL itself. `query` kept an empty part (`&&`) as a pair, gave the raw text for invalid UTF-8 (`%FF`), and started the query at a `?` after the `#`. | `query_all : Request, Str -> List(Str)` (each value, in order) and `query_pairs : Request -> List((Str, Str))` (each pair, in order). All three parse as `URLSearchParams` (application/x-www-form-urlencoded, WHATWG URL): an empty part is skipped, invalid UTF-8 is U+FFFD, the query ends at the first `#`. `query` is the first value of `query_all` (`MODULES.md` 4, "Query parameters"). | Replace a parse of the URL with `req.query_all(name)`. Breaking, 4 edge cases of `query`: (1) an empty part (`?a&&b`) is skipped, so `query("")` is `NotFound`: remove code that read the empty name from `&&`. (2) Invalid UTF-8 (`%FF`) is U+FFFD, not the raw text `"%FF"`: code that matched the raw text matches U+FFFD. (3) A `?` after `#` is in the fragment: a URL like `https://x/p#f?a=1` has no pairs, so read the query before the fragment. (4) A tab, LF or CR in the query of a URL that the app made is removed: do not look for them. Other apps change nothing. |
| `Body.chunk!` fills a chunk to 64 KiB; `Body.chunk_with!` | `chunk!` gave each part of the JS stream: about 4 KiB in workerd, so 28,766 crossings for 110 MB. | `chunk!` adds the next parts that are ready (they complete before a timer of 0 ms) to 64 KiB (`Body.default_fill`). The first part is the only wait, so a slow stream still gives each part when it comes. `chunk_with!(body, { fill_bytes ?: U64, max_bytes ?: U64 })` sets the target and the limit. 110 MB of a Miniflare `fetch` body: 1,760 crossings and 392 ms, it was 28,161 and 1,472 ms (`MODULES.md` 4, "Chunks"). `pass_through!`, `Body.writer!` and WebSocket do not change. | Nothing. Code that needs each part at once (a proxy that writes each part on) uses `chunk_with!(body, { fill_bytes: 1 })`. Code that counted on chunks of about 4 KiB gets larger chunks (at most `default_max`). |
| Docs: `Worker.new({ fetch! })` with one handler | Only a short note in `MODULES.md` 3. | `MODULES.md` 2 shows the error text ("This argument has the type: `Request => Try(Response, _a)`") and the fix `Worker.new({ fetch!: fetch! })`. `{ fetch! }` with one name is a block in Roc, not a record: a language rule, no platform change. | Write `{ fetch!: fetch! }` (or `{ fetch!, }`). |
| zstd: a faster decoder, `ZstdStream.feed!` | `Native` decoded zstd with `std.compress.zstd`: about 40 MB of output per second (basic-cli 0.26.0, 83 MB: 1.9 s of CPU in Node, 2.3 s in workerd). 274 KB of stack for each op. The frame checksum was not checked. One push gave all the output of its chunk: a chunk with a high ratio (a long run of zeros) could pass the 16 MiB push limit. | A pure Zig port of the libzstd 1.5.7 decoder (`hostlib/zstd/`, ReleaseSafe): 470 to 1,000 MB/s (the same file: 0.1 s in Node, 0.18 s in workerd). 6 KB of stack (the reserve is 32 KB, was 300 KB). A wrong frame checksum is `BadFrame`. New: `Native.ZstdStream.feed!(stream, chunk, max_bytes)` gives the output of a chunk in parts of at most `max_bytes` (`{ out, more }`). The API, the window limit, the error tags and the handles are the same. Some damaged frames give other answers (`research/zstd-speed/README.md` 4). | Nothing. For archives from the network, use `feed!` in place of `push!` (call it again with an empty chunk while `more` is `Bool.True`), so a high ratio chunk does not give `OutputLimit`. |
| The test helper: `js/test.mjs` (`startApp`) and `js/test-entry.js`, `"test": 1` in `js/cfw.json` | Each app wrote its own Miniflare harness (the module list, the clock control, the binding counts, the traps of "Testing an app"). | `startApp` of `.roc-cfw/test.mjs` ("Testing an app"). `js/cfw.json` is `{ "api": 1, "test": 1, "min_nightly": ... }`. `roc-cfw` 0.0.1 reads only `api`, and copies both files with the rest of `js/` (checked with 0.0.1). | Replace a harness with `startApp`. Install `wrangler` (or `miniflare`) for the tests. |
| The shim option `wrapEnv` | No supported hook to count or wrap a binding. A subclass of the class of `makeHandler` that replaced `this.env` worked only for `fetch`, `scheduled` and `queue` of the default export. | `makeHandler(app, { wrapEnv: (env, info) => env })`: once per event of each kind (`Fetch`, `Scheduled`, `Queue`, `Email`, `Tail`, `Rpc`, `Init`, `Alarm`, `Socket`, `Other`), after the binding check of the raw `env`. Its result is the root `env` of the task. `info`: `{ kind, name, event }` (`MODULES.md` 3, "The option wrapEnv"). | Nothing. A test uses it through `startApp({ count, hooks })`. |
| `Memo`: a value that does not parse back is logged | A `Memo` value whose type does not round-trip through CBOR (or a `List(U8)` in a `--opt=dev` build with roc-cbor 0.2.2) was pinned, failed its read at each `get!`, and loaded again with no error and no log line, as a pin of an older type after a deploy does (Talon slice 108b: 3 and 12 JWKS loads where 1 was expected). | At a miss, `get!` parses the bytes that it wrote. A value that does not parse back is not pinned, and the shim logs one line for each name in the isolate: `Memo "<name>": the value of load! does not parse back from its CBOR form (InvalidCbor(42) at keys[0].material.Rsa.e[0]). ...`. A pin of an older type still loads again with no log line. Cost: one `Cbor.parse` for each run of the loader (`MODULES.md` 9). | Nothing. If the line shows, change the type (for example `Try(a, [Missing])` in place of `Try(a, [Null])` in a record), or build with `--opt=speed`. |
| roc-cbor 0.2.3 (the `cbor` URL of the platform header) | roc-cbor 0.2.2 read each integer through an `I128`. In a `--opt=dev` build the wasm32 backend narrows an `I128` to `U8`, `U16`, `I8` or `I16` wrongly (roc-lang/roc#12782), so a `List(U8)`, a BLOB into `List(U8)` or `Cbor.Bytes`, and a `Memo` value with a `List(U8)` did not read in a dev build. | roc-cbor 0.2.3 reads small integer types through an `I64`. The platform reads are right in `--opt=dev`, `--opt=speed` and `--opt=size`. Other reads and writes do not change. | An app with the roc-cbor URL in its header (`examples/hello/with_cbor.roc`) moves to the 0.2.3 URL, so the types stay the same. Your own code that calls `I128.to_u8_try` (or `to_u16_try`, `to_i8_try`, `to_i16_try`) is still wrong in a dev build: convert through `I64`. |

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

The platform header has roc-cbor 0.2.3: an app that adds the roc-cbor URL too uses the same URL (`examples/hello/with_cbor.roc`).

The module names do not change. `MODULES.md` 1, "Modules", now marks the low-level modules (`Cbor`, `Native`, `Io`, `Js`): an app needs only `Cbor`, `Native` and the `Io` functions `run!`, `both!`, `all!`, `race!`, `timeout`. `Io.new` and `Io.sync` (for a binding author) stay in `Io`: they cannot move to `Js` (Roc refuses the import cycle).

Needs: a Roc nightly (see "Supported nightlies"), Node (JSPI: the tests use Node 26) and `wrangler` (the tests use Wrangler 4). Install Wrangler on the machine (see the Cloudflare documentation). It is a program, not a file of a project.

### Supported nightlies

Supported nightlies: `nightly-2026-10-19-601b54c` (the `min_nightly` of `js/cfw.json`) to `nightly-2026-11-01-48d3369` (the build of 0.0.4, `compat/last-stack-first-nightly`). A later nightly is not checked before a release: the scheduled job `nightly-layout` builds and tests each new one. Checked 2026-11-02 against the platform at 0.0.3 (`research/min-nightly/`): the conformance app (512 checks in Miniflare, with the `on_trap` checks), `bench/node-test.mjs` and `bench/handler-test.mjs` with the hosts of the release nightly.

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

Use the default build mode (`--opt=speed`) or `--opt=size` for a release. `--opt=dev` also works for the platform: with roc-cbor 0.2.3 its own typed reads (D1 rows, a BLOB, `Memo` values, RPC and queue data) are right in a dev build. Your own code is not safe in a dev build when it calls `I128.to_u8_try`, `I128.to_u16_try`, `I128.to_i8_try` or `I128.to_i16_try`: on nightly 2026-10-31 the wasm32 dev backend gives a wrong result for them, until [roc-lang/roc#12782](https://github.com/roc-lang/roc/issues/12782) is fixed. Convert through `I64`, or build with `speed`.

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
| tar | Not in `Native`. Use roc-tar 0.0.2 (`https://github.com/Karakatiza666/roc-tar/releases/download/0.0.2/ynGk61syE32Lobjgwd3ZNRURf78xPGxr8Nzi1bSuhUr.tar.zst`), a streaming ustar, pax and GNU reader in pure Roc that takes the output of `Native.ZstdStream` | `MODULES.md` 1 |
| An HTTP method that workerd does not know (`BREW`) | `501 ERROR: Unrecognized request method.` from workerd. The Worker does not run | `API.md` 10.1 |
| A D1 bookmark in local D1 | Local D1 takes any bookmark text in `with_session!(After(b))`. A local test cannot check a bookmark | `MODULES.md` 5.1 |
| `.wrangler/` directories | `wrangler dev`, `wrangler d1 execute --local` and `getPlatformProxy` write local state in `.wrangler/` next to the Wrangler config, also when you run them from another directory (for example a test harness in `tests/` that names `../wrangler.toml`). A harness in a directory with its own config makes its own `.wrangler/` there. The template `.gitignore` has the line `.wrangler/`, which matches a `.wrangler/` directory at each depth. Delete these directories for a clean test: they hold the local D1, KV and R2 data | |

## Testing an app

The release has a test helper: `.roc-cfw/test.mjs` (Node) and `.roc-cfw/test-entry.js` (the part in the isolate). `roc-cfw shim` copies both with the rest of `js/`. It runs the built app (`app.wasm` and the shim) in Miniflare with local bindings, with no `.wrangler/` dir and no network. The design and the rules TH1 to TH19 are in `research/design-notes/test-helper.md`.

```js
// tests/app.test.mjs (node --test, or a plain script). The project has app.wasm and .roc-cfw/ (roc-cfw sync).
import { startApp } from '../.roc-cfw/test.mjs';

const app = await startApp({
  dir: '.',                                       // app.wasm, .roc-cfw/, worker.options.js, wrangler.toml
  now: 1767225600000,                             // the shim clock (Time.now_ms!, Memo, deadlines); null: the real clock
  d1: { DB: ['sql/0001_init.sql', 'tests/seed.sql'] },   // .sql files or SQL texts, run in order
  kv: { CACHE: { key: 'value' } },
  r2: { BUCKET: { 'a/b.txt': 'text' } },
  outbound: { 'GET https://api.github.com/repos/o/r': [{ status: 200, body: '{}' }, { status: 304 }] },
  count: ['DB'],                                  // count the calls of these bindings
});
const res = await app.fetch('/v1/x', { method: 'POST', body: '{"a":1}', headers: { 'content-type': 'application/json' } });
res.status; await res.text(); res.calls.DB.n;     // the D1 calls of this request
await app.reset();                                 // D1, KV, R2, the Cache API, the clock, the Memo pins: back to the start
await app.close();
```

| Call | Gives |
| --- | --- |
| `startApp(opts)` | The app in Miniflare. Options: `dir`, `wasm` (any path), `shim` (default `.roc-cfw` of `dir`), `config`, `now`, `d1`, `kv`, `r2`, `queues` (consumer settings), `outbound` (a table or a Node function), `services` (Node functions for service bindings), `bindings` (vars and secrets, on top of `vars` of the config), `compatibility` (`{ date, flags }`, default: the config), `count`, `hooks` (a module in the isolate), `options` (JSON `makeHandler` options on top of `worker.options.js`), `miniflare` (a dir or the module), `persist`, `modules`, `cf`, `miniflareOptions` (V4 options on top; a `ratelimits` key adds to the rate limits of the helper, any other key replaces the key of the helper), `ratelimits` (`{ NAME: { limit, period } }`, see Bindings) |
| `app.fetch(pathOrUrl, init)` | A `Response` with `calls` (`{ DB: { n, ops, list: [{ op, session, kind, name }] } }`, the calls of the tasks of this request only; a queue `send` item also has `body` and `contentType`, a `sendBatch` item `bodies`: see Count) and `sessions` (`{ DB: [withSession arguments] }`). `init.now`: the clock before the request |
| `app.setNow(ms \| null)`, `app.advance(ms)`, `app.now` | The shim clock, through a control path (no Roc task, so no sweep). `app.now` is a getter: the clock of the isolate (`Time.now_ms!`), or `null` when the clock is real time (`Date.now`) |
| `app.scheduled({ cron, time, now })` | `{ outcome, noRetry }` of `/cdn-cgi/local/scheduled` |
| `app.queue(name, messages, { now })` | The result of the `queue` handler: `{ outcome, ackAll, retryBatch, explicitAcks, retryMessages }`. A message with no `timestamp` gets the helper clock |
| `app.d1(name)`, `app.kv(name)`, `app.r2(name)`, `app.queueProducer(name)`, `app.object(name)` | The Miniflare handles |
| `app.sql(name, texts)` | SQL between requests, split as the seeds (one statement at a time; a trigger body stays whole) |
| `await app.calls({ reset })` | Each counted call of any task since the last reset (`Response.after` work, objects, alarms) |
| `app.idle(ms = 5000)` | Waits until the shim has no task (a throw with the count after `ms`) |
| `app.outbound()` | `{ log: ['GET https://...'], count: { 'GET https://...': 2 }, unmatched: [...] }` |
| `app.reset()` | Waits for `idle`, then: D1 (drop the user tables and views, run the `d1` seeds again), KV and R2 (delete each key, seed again), the Cache API keys that the app put (`caches.default` and `caches.open(name)`), the clock (the `now` of the start), the pin table (`Memo`, `Js.pin!`), the calls, the outbound log and the answer order, `app.logs`. The isolate and the wasm stay. The rate limit counters (the key of each `limit` call gets a prefix with the number of resets: Miniflare keeps the counters in a Durable Object that Node cannot clear, so the old counters stay but are not used again). Not reset: Durable Object storage and alarms, queue messages in flight, module globals of JS (`ops`, `hooks`) |
| `app.logs` | The structured log lines of workerd |
| `app.close()` | Disposes Miniflare and removes the run dir |
| `app.mf`, `app.url` | The Miniflare instance and its URL (no promise of stability) |
| `TEST_API` (export) | `1`, equal to `test` of `cfw.json`. A breaking change of `startApp` adds 1 |

| Rule | What the helper does |
| --- | --- |
| Bindings | It reads the manifest of the wasm in Node. Each declared D1, KV, R2, queue producer, rate limit and object class of this Worker is made, seeded or empty (an object class is SQLite-backed). A rate limit binding (`RateLimit.binding`) gets `{ limit, period }` from the option `ratelimits`, else from `[[ratelimits]]` or `unsafe.bindings` of type `ratelimit` in the config (`simple`, `namespace_id`), else `RATELIMIT_DEFAULT` (export of `test.mjs`): 100 in 60 s. Miniflare allows `period` 10 or 60 only (else a throw). Miniflare counts by the real wall clock, not by `app.setNow`. A seed of a binding that the app does not declare is a throw with its name. A kind with no local form (`ai`, `vectorize`, a service) needs `services`, `bindings` or `hooks`. Queue consumers: the `queues.consumers` of the config. A config with no `queues.consumers` and an app with a `queue` handler: the Worker consumes each of its producer queues, so its own sends go to its `queue` handler. To keep the sends in the queue (a test that checks only `calls`), put `consumers = []` in `[queues]` of the test config. A D1 seed text runs as one batch; when the batch fails, its statements run again one at a time, so the error names the bad statement |
| Count | `count: [names]`. A call is one round trip: D1 `all`, `run`, `first`, `raw`, `batch`, `exec` (`prepare`, `bind`, `withSession` are not calls); KV `get`, `getWithMetadata`, `put`, `delete`, `list`; R2 `get`, `head`, `put`, `delete`, `list`, `createMultipartUpload`, `resumeMultipartUpload`; a queue `send`, `sendBatch`; a rate limit `limit`. A queue `send` item in `list` also has `contentType` and `body`: `{ bytes (base64), size, value?, truncated? }`. `bytes` is the CBOR of the message (the UTF-8 for a text, the raw bytes for the type `bytes`), `value` the decoded value (a `BigInt` is `{ $bigint }`, a byte string is `{ $bytes }`). A `sendBatch` item has `bodies`, one such object (with `contentType`) for each message, and counts as one call. `delaySeconds` is kept when the call gives it: on a `send` item, on each message of `bodies`, and on a `sendBatch` item for the batch options (0.0.5). `bytes` keeps 4096 bytes at most (`BODY_MAX` of `test-entry.js`; `size` is the full length): a longer body has `truncated: true` and no `value`, because the calls of a request travel in a response header. The count uses the shim option `wrapEnv` (`MODULES.md` 3) |
| Hooks | `hooks: 'tests/hooks.js'`: a module in the isolate. Its exports `wrapEnv(env, info)` and `fetch(request, env, next)` run after the count. Its local imports are in the module list |
| Outbound | A table `{ 'METHOD url': [answer, ...] }`: each request to a key takes the next answer, then the last again. An answer is a `Response`, or `{ status, headers, body, chunked }`. The helper sets `Content-Length` from the body. `chunked: true` sends the body in chunks with no length: use it for a byte count or a size limit test (workerd frames a body by its `Content-Length`: a smaller value cuts the body, a larger one makes the read wait). A request with no key gets a 599 and goes to `unmatched`. A Node function in place of the table, or of one answer, gives a `Response` or an answer object |
| Run dir | `<tmp>/cfw-test-<pid>-<n>` for each app, and `TMPDIR` is `<tmp>/cfw-test-<pid>` (the `miniflare-*` dirs) while an app runs. `close`, exit, SIGINT and SIGTERM remove them |
| Miniflare | The option `miniflare`, env `MINIFLARE`, `miniflare` or `wrangler/node_modules/miniflare` from the project, the global wrangler of this node. Else a throw with each place. Tested with wrangler 4.151.0 (Miniflare 5.20261012.0-beta, `convertV4MiniflareOptions`) |
| Options file | `worker.options.js` and its relative imports are in the module list. An import that is not relative (an npm package) is a throw: give it in `modules`, or bundle the file |

The traps of a test setup. The helper avoids T1 to T3, T5, T6 and T8 by default.

| Trap | Effect | The helper |
| --- | --- | --- |
| T1 | `dispatchFetch` with a string body adds `Content-Type: text/plain;charset=UTF-8` | Sends a text body as UTF-8 bytes |
| T2 | Node `fetch` (undici) adds `Cache-Control: no-cache` and `Pragma: no-cache` to a request with `If-None-Match` | `cache: 'force-cache'` when the test gives no `cache` |
| T3 | `wrangler d1 execute --local` and `getPlatformProxy` make `.wrangler/` dirs next to the config | Uses neither: the state is in memory (or under the run dir with `persist`) |
| T4 | Local D1 accepts any bookmark (`withSession("bookmark-abc")` gives no error) | No fix: `res.sessions` records the argument |
| T5 | Miniflare leaves `miniflare-*` temp dirs after a kill | Its own `TMPDIR`, removed on exit and on a signal |
| T6 | With no `cf` option, Miniflare fetches `request.cf` from the network at start | A fixed `cf` (option `cf`) |
| T7 | A clock that jumps forward makes the next sweep cancel the tasks in flight past their deadline, also `Response.after` work | No fix: move the clock when `app.idle()` is done. `Date.now()` of JS, the Cache API `max-age` and alarm times stay on the real clock |
| T8 | `redirect: 'follow'` of `dispatchFetch` hides a 3xx of the app | `redirect: 'manual'` |
| O1 | The helper marks each request with the header `cfw-test-request` | The isolate part removes it before the app runs (the copy keeps `request.signal`) |

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
