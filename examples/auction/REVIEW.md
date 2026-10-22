# Gavel on the final API of step 8h: review

Gavel is moved from the API before step 8h to the final API. Roc nightly `compat/last-stack-first-nightly` (2026-10-12). Line numbers are of the files in this directory.

## 1. Line counts

| File | Before (main) | After |
| --- | --- | --- |
| `Gavel.roc` | 84 | 86 |
| `LotRoom.roc` | 225 | 222 |
| `web.roc` | 194 | 183 |
| `ledger.roc` | 166 | 159 |
| `worker.js` | 8 | 7 |
| `worker-ledger.js` | 6 | 5 |
| `wrangler-web.toml` | 39 | 40 |
| `wrangler-ledger.toml` | 29 | 30 |
| Total | 751 | 732 |

The Roc code is 669 lines before and 650 after (19 fewer). The count does not show the main gain: the code has less noise (no `Int(` wraps, no race match, no broadcast loop), but the shared error types and the `bindings` lists add lines. The two `worker*.js` files are written by `sync`. The two toml files changed in comments only: they passed `sync --check` at once.

## 2. Old friction points

| # | Old friction | How it reads now | Where | Result |
| --- | --- | --- | --- | --- |
| 1 | One closed error type `Fault` for all handlers of the class (old `LotRoom.roc:25`) | Each handler has its own `_` error. The three Rpc handlers must fit `Gavel.RoomErr` | `LotRoom.roc:58`, `65`, `90`, `126`, `168`, `187`, `202`, `210`. `Gavel.roc:28` | Better for the plain handlers. The Rpc handlers still share one long union (new friction N5) |
| 2 | RPC errors were text (`Rpc(arg, ret)`) | `Rpc(arg, ret, err)`. The caller can match `Remote(NotOpen)` | `Gavel.roc:35` to `44`. `web.roc:64` to `68` | Better. `create_lot!` still passes the whole error up (`web.roc:134`) |
| 3 | `Int(x.to_i64_wrap())` and `Text(...)` around each SQL parameter | Tuples and lists of plain values | `web.roc:103`, `127`, `133`. `ledger.roc:48`, `70`. `LotRoom.roc:122` | Better. 6 wraps are gone from `web.roc` alone |
| 4 | Re-match of `NotFound` to give a default (old `Gavel.roc:70`, old `ledger.roc:44`) | `get_or!` on a `Kv.Cell` | `Gavel.roc:67`. `ledger.roc:46` | Better for Kv. For `Object.Cell` the re-match stays (N6) |
| 5 | `Dec` for the FX rate, because JSON did not take `F64` | `F64` in the type, the feed tick and the receipt math | `Gavel.roc:23`. `ledger.roc:31`, `80` | Works, but it was not a gain (N10). Done: `Dec` again |
| 6 | R2 etag by hand: read `if-none-match`, cut the quotes, match `PreconditionFailed` (old `web.roc:148` to `160`) | One call, `images.respond!(key, req)` | `web.roc:144` | Much better: 13 lines to 1, and it also does ranges and 412 |
| 7 | `Io.race!` with `Got` and `TimedOut` tags and `got.result` (old `ledger.roc:117`) | `ws.receive().timeout(ms).run!()` | `ledger.roc:114` to `127` | Better. The loop still computed the time left (N9). Done: `timeout_at` |
| 8 | `{}` and `()` mixed for no argument (`Time.now_ms!({})`, `\|{}\|` for `load!`) | `()` for each no-argument function and callback | `Gavel.roc:67`, `80` to `81`. `web.roc:118`. `ledger.roc:45` | Better. `{}` is left only as an Rpc argument value (N8) |
| 9 | Binding names only as strings, checked at the first call on the edge | `bindings:` list in `Worker.new`, checked by `sync` and at load | `web.roc:176` to `181`. `ledger.roc:152` to `157` | Better. The list is optional and by hand (N7) |
| 10 | Untyped namespace stubs: `Object.namespace("LOT_ROOM")` | `Object.namespace(name, { class })`, and `script` in the ledger. `call!` takes a typed `Rpc` | `web.roc:30`. `ledger.roc:23` | Better for the config check. The stub is still not tied to its class (N4) |
| 11 | Broadcast loop over `sockets!()` with `send!` (old `LotRoom.roc:146`) | `self.broadcast!(message)` | `LotRoom.roc:129`, `177` | Better. The count result must be dropped (N11) |
| 12 | Attachment: `socket.attach!({...})` and `socket.attachment!()` with an annotation at the use (old `LotRoom.roc:72`, `113`) | A constant `bidder_slot : Object.Attachment(Bidder)` | `LotRoom.roc:22` to `23`, `72`, `117` | Better. One type for write and read |
| 13 | `set_alarm!(lot.close_ms)`: not clear that the time is absolute | `set_alarm_at!` | `LotRoom.roc:195` | Better |

Also used from the list: `Worker.new` (`web.roc:176`, `ledger.roc:152`), `Worker.cron` (`web.roc:180`, `ledger.roc:156`, so `UnknownCron` and the `match s.cron` are gone), `declare()` (`web.roc:179`, `ledger.roc:155`), `Rpc.on_worker` (`ledger.roc:154`), `Kv.cell` (`Gavel.roc:53` to `57`, `web.roc:36` to `37`), `Response.after` for the catalog cache write (`web.roc:98`), `req.method()`, `req.query`.

Not used, with the reason:

| Item | Reason |
| --- | --- |
| `Id64` | The lot ids are text (`"l1"`), and the bids table key is not shown to a client. Nothing to move. |
| `Cache` | The catalog must be removed when a lot is created (`web.roc:137`). The Cache API is for one data center, so a delete in one place does not clear the others. The KV cell has the same 60 s delay, but one place to delete. |

## 3. Build results

| Check | Result |
| --- | --- |
| `roc build --target=wasm32 --no-cache` of `web.roc` | 0 errors and 0 warnings, 16.0 s |
| `roc build --target=wasm32 --no-cache` of `ledger.roc` | 0 errors and 0 warnings, 11.4 s |
| `roc fmt examples/auction/*.roc` | done |
| `sync --check` for `web.wasm`, `worker.js`, `wrangler-web.toml` | exit 0 |
| `sync --check` for `ledger.wasm`, `worker-ledger.js`, `wrangler-ledger.toml` | exit 0 |
| `roc test examples/auction/ledger.roc` (the `expect`) | passes. With `fee_percent / 100` changed to `/ 10`: 1 failed. With `*` changed to `/` in the rate math: 1 failed. Restored: passes. |

Run the commands from the repository root (N2). `sync` needed `--force` once: the old `worker.js` had no "Made by" line.

## 4. New friction

| # | Friction | Where | Idea |
| --- | --- | --- | --- |
| N1 | Compiler crash. A `call!` of an `Rpc` whose answer is `{}` (`Rpc(Lot, {}, RoomErr)`) crashes `roc build` of `web.roc` (SIGSEGV, or `guarded list invalidated: monotype.Type.Store.fields`, the text changes between runs). Minimal repro: a `fetch!` that has only `lot_rooms.named("x").call!(Gavel.open, lot)?`. A `Str` answer compiles. An error type of `[NotOpen]` or `Rpc.NoErr` crashes too, so the answer type is the cause. The old `Rpc(Lot, {})` compiled. Fixed: the compiler bug is the derived parser of a tag with a `{}` payload (fixed upstream in nightly-2026-10-19). `Rpc.reply_of` now reads the reply head by hand (research/rpc-unit-crash), and `open` answers `{}` again. | `Gavel.roc:35`. `LotRoom.roc:187`, `196` | Done: conformance `rpcerr an answer {}` (entry point, named entry point, object) and the auction shape with `?`. |
| N2 | `roc check` said "No errors found" while `roc build` of the same files gave 2 type errors (`req.body` as a field in `web.roc`, `{ name }` as a record in `LotRoom.roc`). The `check` came first and showed none, so the build was the only way to see them. Also, `roc build` run inside `examples/auction/` gives `PathOutsideWorkspace` (the header says `../../platform/main.roc`). Run it from the root of the repository. | `web.roc:150`. `LotRoom.roc:72` | The README of the example must say "build from the root". Do not trust `roc check` alone for an app. Done: docs (`examples/auction/README.md`, `README.md`, `MODULES.md` 2); the check/build difference did not reproduce (research/check-vs-build). A `roc build` with errors still writes the `.wasm` and exits with 1: a build is good with exit 0 and "0 errors and 0 warnings". |
| N3 | A record with one field is a block: `{ name }` gave the error "Str, but set! needs { name: Str }". The message is good, but the trap is still there with typed attachments and cells (the value is often a one-field record). | `LotRoom.roc:72` | None for the platform. Maybe a note in MODULES.md 12.1, where the example has `{ name: ... }` with one field. Done: a note in `MODULES.md` 12.1 and 9 (`{ name: name }`). |
| N4 | A namespace is not tied to its class. `lot_rooms.named(id).call!(Gavel.open, lot)` compiles for an `Rpc` that the class does not have (MODULES.md 7, "Not built"). The class name is written twice: in `Object.class("LotRoom", ...)` and in `Object.namespace(..., { class: "LotRoom" })`. | `web.roc:30`. `ledger.roc:23`. `LotRoom.roc:31` | A `Gavel.room_class_name` constant that both use, or `Object.namespace_of(LotRoom.class)`. Done: `Object.namespace(name, { class: LotRoom.class })` takes the `Object.Class` value (`web.roc:30`). The ledger has no class value (the class is in auction-web), so it uses `Object.namespace_remote(name, { class: "LotRoom", script: "auction-web" })` (`ledger.roc:23`). The types still do not tie the namespace to its Rpc methods (MODULES.md 7). |
| N5 | A closed Rpc error type forces a long union. The handler's `?` adds the tags of storage and SQL, so `RoomErr` lists `StorageErr`, `SqlErr`, `Constraint`, `BadData`, `TooLarge` besides the 3 tags of the domain. Each method has all 8 tags, and the caller has `Remote(...)` of all of them, with a `_` arm in `error_response!`. | `Gavel.roc:28`. `web.roc:64` to `77` | Let the platform map an infrastructure error of the callee to `RpcErr` and keep only the domain tags in `err`. Or a `Rpc.Infra` helper tag. Done (N5 option G1a, `research/n5-rpc-errors/README.md`): each platform function gives its storage, binding and call errors as `Infra([its own tags])`. `RoomErr` is `[NotOpen, AlreadyOpen, StillOpen, Infra(Rpc.Infra)]`, `SettleErr` is `[Infra(Rpc.Infra)]` (`Gavel.roc`). `error_response!` matches `Remote(StillOpen)` and `Remote(Infra(StorageErr(_)))` (503), and `Infra(Constraint(_))` (409). `Rpc.forward` maps the error of a nested call. |
| N6 | The `NotFound` re-match of `Object.Cell.get!` stays. A closed error needs each tag listed again (`load_state!`, `open!`). `Err(e) => Err(e)` works only where the error type is open `_` (`alarm!`), and it then carries `NotFound` that never occurs. | `LotRoom.roc:81` to `87`, `188` to `199`, `171` | `Object.Cell.find!` that gives `Try(Try(a, [NotFound]), errs)`, or `get_or_else!(self, \|\| error)`. Done: `Object.Cell.find!`, `Kv.find!` and `Kv.Cell.find!` give `Try(Try(a, [NotFound]), errs)`. `load_state!`, `alarm!` and `open!` in `LotRoom.roc` use it: no re-match of `BadData` and `StorageErr`, and `alarm!` has no `NotFound` in its error type. |
| N7 | The `bindings` list is a second list of the bindings, and it is optional. A forgotten binding is not checked, and no compile error shows it. `Kv` needs a `Kv.text("KV")` handle only for `declare`, because the typed values are cells and the cells have no `declare`. The same name `"KV"` is written 4 times. | `Gavel.roc:50` to `57`. `web.roc:37`, `179`. `ledger.roc:155` | `Kv.Cell.declare`, or `kv.json_cell("config")` from one `Kv` binding. A lint in `sync`: a binding that the Roc code names but `bindings` does not. Done: `Kv.Cell.declare()`: `web.roc` has `catalog.declare()`, `ledger.roc` has `Gavel.config_cell.declare()`, and the `Gavel.kv` handle is removed. The shim warns once for each undeclared binding that the code reads (MODULES.md 3), and `sync` prints a note for a config part that `bindings` does not name. |
| N8 | `{}` stays for an Rpc argument. The caller writes `call!(Gavel.snapshot, {})`, and the handler writes `\|self, {}\|`. A reader sees `()` for no-argument functions and `{}` for no-argument Rpc methods, two rules. | `web.roc:108`, `171`. `LotRoom.roc:203`, `211`. `ledger.roc:42`, `147` | `Rpc(Unit, ret, err)` with `call!(Gavel.snapshot)`. Accepted: `{}` stays for an Rpc argument (one rule: `()` for functions, `{}` for a value). |
| N9 | `Io.timeout` is for one `Io`. The feed loop has one deadline for all reads, so each turn still computes `deadline - now` and reads the clock twice. | `ledger.roc:105` to `114` | `Io.timeout_at(io, deadline_ms)`, or a `Time.deadline(ms)` value that gives the time left. Done: `Io.timeout_at(io, deadline_ms)` (`platform/Io.roc`, helper `pf.waitUntil`); `ledger.roc` uses it, with no clock read in the loop. |
| N10 | `F64` is not a gain for money math. The rate is `F64`, so the receipt turns cents to `F64`, multiplies, and goes back with `round_to_u64_try() ?? 0`. The `?? 0` hides an out-of-range result, and cents above 2^53 lose digits. The old `Dec` had none of these. The JSON now accepts `F64`, which is what a feed gives, but the code after it prefers `Dec`. | `ledger.roc:80`. `Gavel.roc:23` | A `Dec.from_f64` and `Dec.round_to_u64`, or keep `Dec` in the type and let the JSON reader take a number. Done: `Dec` again (`Gavel.roc:23`, `ledger.roc`). The builtin `Json` reads a `Dec` from a number (`0.9183`, `2`, `1.5e-2`, 18 digits) and writes it as a number. The `?? 0` is gone: an amount that does not fit in `U64` leaves the currency out of the receipt. Done (2026-10-22): the multiply no longer crashes above 1.7e20 (`Dec.times_saturated`, there is no `times_try`; the saturated value is out of the `U64` range), with an `expect` in `ledger.roc`. The fee (`cents * percent / 100`) uses `times_try` and an exact split on overflow (`fee_of`), with an `expect`. |
| N11 | `self.broadcast!` takes a `WebSocket.Message` and gives a `U64` count that must be dropped with `_ =`. For JSON, the app writes `Text(Json.to_str(...))`. `Object.Socket` has `send_json!`, but `Self` has no `broadcast_json!`. | `LotRoom.roc:129`, `177` | `broadcast_json!(self, value)`. Give the count in a `_with` form, so the short form gives `{}`. Done: `broadcast!` gives `{}`. `broadcast_json!(self, value)` gives `Try({}, [BadData(Str)])`, and `broadcast_json_with!` gives the count. `broadcast_with!({ tag ?: Str }, msg)` gives the count (`{}` for all sockets). `LotRoom.roc:129`, `177` use `broadcast_json!`. |
| N12 | `Sql.none` needs `import pf.Sql` only for the empty list. A bare `[]` does not compile. Each statement with no parameter has the import. | `Gavel.roc:83`. `web.roc:96`. `LotRoom.roc:60`, `93` | A `db.exec!(sql)` form exists for D1 but not for `all!`, `sql!` and `sql_run!` of an object. Add `all_plain!`, or take `[]`. Accepted: `Sql.none` stays (one import for the empty list). |
| N13 | The `Response.after` closure for the cache write works and reads well, but the result of the work (`KvErr`) goes only to a log line. Nothing in the types says that the list handler has no way to tell the client. This is the wanted design, but the first read of `web.roc:98` does not show where the error goes. | `web.roc:98` | A doc line on `Response.after` that names the log line `fetch: after respond: failed: ...`. Done: doc lines on `Response.after` (`platform/Response.roc`, `MODULES.md` 4, `API.md` 10.2): the error is the log line `fetch: after respond: failed: <Str.inspect(e)>`, never the client. |
| N14 | The compensation in `create_lot!` is by hand: insert a row in D1, call the room, and delete the row when the call fails. The delete error is dropped (`_ =`). No API gives one unit of work over D1 and an object. This is the same as before the step. | `web.roc:125` to `136` | None for the platform (no distributed transaction). A sentence in the docs about the pattern. Done: `MODULES.md` 5.5 (the compensation pattern). `web.roc` logs a failed delete with `Log.error!` and still returns the error of the room. |
