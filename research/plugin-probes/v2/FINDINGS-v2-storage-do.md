# Findings v2: Durable Objects, WebSockets, RPC, D1, R2, KV, Cache, Queues

Platform HEAD as pinned by `0.0.1-local` (`GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As`), compiler nightly-2026-10-19-601b54c.
Replaces the traps of `../FINDINGS-do.md` and `../FINDINGS-storage.md` for the 7 topics `cfw_objects`, `cfw_websockets`,
`cfw_rpc`, `cfw_d1`, `cfw_r2`, `cfw_kv_cache` and `cfw_queues` of the plugin `cloudflare-workers`.

Kinds: `fixed` (old trap, HEAD fixed it, dropped from the topics), `kept` (still true, checked again), `new` (not in the old
files), `drift` (a platform doc disagrees with HEAD), `fact` (run time fact that a topic states).

Found by: a probe file in this directory (`do_*`, `st_*`: compile only), `st_run` (a local `wrangler dev --local` run of
`st_run/main.roc`), `st_smoke.sh` (build of the 7 topics, `sync` loads each manifest), `st_smoke_out/run_*.toml` and
`st_smoke_out/st_ws_client.mjs` (a local run of each topic app), or the platform docs (`MODULES.md`, `platform/*.roc` comments).

## Old traps that HEAD fixed

| # | Finding | Found by | Kind |
| --- | --- | --- | --- |
| 1 | The time `Time.now_ms!()` (U64) goes into SQL as it is: `[now]`. No `to_i64_wrap`. A U64 above 2^63-1 is `BadParam` at run time (old D1, S4) | `do_objects.roc` compiles; `st_run` route `u64over` | fixed |
| 2 | One error type for all handlers of a class: a handler with `Try(Response, [])` next to one that uses `?` compiles (old D4, p9, p12) | `do_p02.roc` | fixed |
| 3 | `Rpc(arg, Try(ret, err))` had no codec. The error is now its own type argument: `Rpc(iface, arg, ret, err)`, and the caller gets `Remote(err)` (old D3, X10) | `do_rpc.roc`, `st_smoke.sh` | fixed |
| 4 | `set_alarm!` took an absolute time. Now `set_alarm_at!` (absolute) and `set_alarm_in!` (delay) (old R1). The name now says it, so the topic has one line, not a trap | `st_run` route `ticker/in` | fixed |
| 5 | A SQL parameter is no longer a `Sql` tag: `[name]`, `(a, b)` (old S3, S4). The old form is now a different trap, see 28 | `st_d1.roc`, `st_run` | fixed |
| 6 | A D1 BLOB column reads into a `Cbor.Bytes` field and into a `List(U8)` field (old R1 of storage said `BadData`) | `st_run` routes `blob_list`, `blob_cbor_bytes` | fixed, drift (the "As built" row of `MODULES.md` 5.1 still says `BadData`) |
| 7 | R2 `put!` of a stream with no known length (`Body.writer!`) works: one put up to 5 MiB, a multipart upload above (old R4) | `st_smoke_out/run_r2.toml`, route `generated` gives 201 and the right body | fixed |
| 8 | KV `ttl_ms` under 60 s is raised to 60 s and gives `Ok` (old R6) | `st_run` route `kv_ttl` | fixed |
| 9 | `Cache.put!` tees a stream body, so the client still gets it (old R7). `Ctx.wait_until!(cache.put(..))` does not compile now, see 43 | `st_smoke_out/run_kv_cache.toml`: second `/feed` is a `CF-Cache-Status: HIT` after `put_after!` | fixed |
| 10 | `Ctx.respond!` is gone (old WebSocket and R2 notes about reading the body before `respond!`). `Response.after` replaces it | `MODULES.md` 11, `do_websockets.roc` | fixed |
| 11 | `attach!` and `attachment!` took any type, so `attach!({ name })` stored a `Str` (old D2). `Object.attachment(name)` is typed, and the same code is a compile error | `do_p30.roc` | fixed |
| 12 | `Time.now_ms!({})` and other `{}` calls: functions with no argument take `()`. The old form is a compile error ("expects 0 arguments") | `design_issues_tmp.md` row 4, compile | fixed |

## Old traps that are still true (the topics keep them)

| # | Finding | Found by | Kind |
| --- | --- | --- | --- |
| 13 | `self.sql!` with no annotation, and only `rows.len()` on the result: "never resolved to a concrete type" (old D5) | `do_p03.roc` | kept |
| 14 | `D1.all!` straight into `Response.from_json` has no row type: "encoder_for ... never resolved" (old S2) | `st_p22.roc` | kept |
| 15 | A row field used only with a method (`row.n.to_str()`): "requires the parser_for method ... `{ n: a }`" (old S5) | `st_p23.roc` | kept |
| 16 | `{ name }` with one field is a block. `call!(m, { by })` is "I64, but call! needs { by: I64 }". In a lambda with a destructured argument the error points at the line that binds the name, not at the call | `do_p01.roc`, first draft of `cfw_rpc.roc` | kept |
| 17 | `R2.Http` fields are optional: `meta.http.?content_type`, never `meta.http.content_type` (old S1) | `st_p30.roc` | kept |
| 18 | A `Body` is a tag: `Text("x")`, `Bytes(list)`. A bare string is "used where a non-string type is needed ... Body" (old S6) | `st_p30.roc` | kept |
| 19 | An unannotated `Kv.json` binding takes the type of its first use, and a second use with another type fails there (old S8) | `st_p33.roc` | kept |
| 20 | A class with no `alarm!` has no `alarm` method: `set_alarm_at!` and `set_alarm_in!` give `StorageErr` ("must have an alarm() handler"). `set_alarm_at!(60_000)` is in 1970, and the alarm runs at once | `st_run` routes `room`, `ticker/at_bad`, `ticker/state` (`fired=1`) | kept, fact |
| 21 | `all_tuples!` into a record type type-checks, and each read is `BadData("row 0: the row does not fit the type")`. A tuple type with `Try(Str, [Null])` works | `st_p37.roc`, `st_run` routes `tuples_record`, `tuples_ok` | kept |
| 22 | `cache_ttl_ms` of `Kv.get_with!` under 30 s is `KvErr` ("Cache TTL must be at least 30"). The module does not raise it, as it does for `ttl_ms` | `st_run` route `kv_cache_ttl` | kept |
| 23 | D1 gives a number above 2^53 rounded. A typed read is `BadData` with the fix in the text. `CAST(id AS TEXT)` into an `I64`, `U64` or `Id64` field is exact | `st_smoke_out/run_d1.toml`: `events` route gives `9007199254740993` exact | kept |
| 24 | `Kv.put_with!` metadata must be `Kv.Metadata.of(rec)`, not a bare record (old note) | `st_p34.roc` | kept |
| 25 | The `Meta` of `R2.Upload.complete!` has no `http` and no `custom` on the edge: use `head!` (old R5, `design_issues_tmp.md` X9, open) | docs (`platform/R2.roc`, `MODULES.md` 5.3) | kept, fact |
| 26 | A function that the app defines but does not put in `Worker.new` or `Object.class` never runs, with no warning (`design_issues_tmp.md` X8) | `do_p37.roc` | kept |
| 27 | Storage calls with no wait between them are atomic. `init!` must be idempotent. The class must be in `new_sqlite_classes`. The export line must come before `makeHandler` (now written by `sync`). An RPC call cannot carry a socket. An attachment is 16,384 bytes or less. `batch.queue()` is the queue name. `Queue.json` cannot send an integer above 2^53 | docs (`MODULES.md` 7, 8, 12, 6, 1); `st_smoke.sh` prints the Wrangler parts | kept, fact |

## New traps

| # | Finding | Found by | Kind |
| --- | --- | --- | --- |
| 28 | A bare parameter (`db.run!(sql, "ann")`, `5`) and a tag (`[Text("ann")]`, `[Int(9)]`) COMPILE. At run time they are `BadParam`: "SQL parameters must be a list or a tuple, not string: write [x] for one parameter ...", and "a record or a tag is not a SQL value". `(x)` is not a tuple | `st_p20.roc`, `st_p25.roc`; `st_run` routes `bare`, `bare_str`, `tuple1`, `tag` | new |
| 29 | `[]` as parameters does not compile ("encoder_for ... item ... never resolved"). Write `Sql.none` | `st_p20.roc` | new |
| 30 | A NULL column reads only into a field of the type `Try(a, [Null])`. `Str`, `Try(Str, [Missing])`, `[Null, Some(Str)]` and `name ?: Str` are all `BadData("column name: the value does not fit the type")` | `st_run` routes `null1` to `null5` | new |
| 31 | Row field rules (D1 and `Object.Self.sql!`): a `Bool` field is `BadData` (SQLite has 0 and 1); an INTEGER column does not read into `Str`; an INTEGER reads into `F64`; a REAL with no fraction reads into an integer; `2.5` into `I64` is `BadData`; extra columns are ignored; a field with no column is `BadData("column z: missing")`; a camelCase alias does not map to a snake_case field | `st_run` routes `ty_bool`, `ty_f64_from_int`, `ty_str_from_int`, `ty_i64_from_real`, `ty_i64_from_frac`, `ty_extra_col`, `ty_missing_col`, `ty_camel` | new |
| 32 | A bare `Id64` field in `Response.from_json` gives "requires the encode_bytes method ... `JsonEncoding`", with no word about `Id64`. Write `id.to_web()` | `st_p24.roc` | new |
| 33 | `Sql.Info.last_row_id` is a `Try(I64, [Rounded])`: `info.last_row_id.to_str()` is a missing method | `st_p25.roc` | new |
| 34 | `D1` constraint kinds: a primary key conflict is `PrimaryKey`, not `Unique`. A handler for duplicates needs both | `MODULES.md` 5.1 table; `st_smoke_out/run_d1.toml`: UNIQUE column gives `Unique` and 409 | new |
| 35 | An `Rpc` constant without an annotation is "polymorphic value" (the `err` is open) | `do_p11.roc` | new |
| 36 | A method with `Rpc.NoErr` cannot be served by a handler that uses `?` on a platform call (type mismatch, `Infra([...])` against `Rpc.NoErr`). Use `[Infra(Rpc.Infra)]` | `do_p07.roc` | new |
| 37 | A call of a method of another interface gives one clear mismatch error, then 3 "never resolved" errors for `arg`, `ret`, `err`. Read the first | `do_p08.roc`, `do_p15.roc` | new |
| 38 | A list `rpc: [a.on_worker(..), b.on_worker(..)]` with methods of two interfaces: "The two elements in this list have incompatible types ... `Rpc.Serves(Front, {})` ... `Rpc.Serves(Back, {})`" | `do_p14.roc` | new |
| 39 | The RPC argument for "no argument" is `{}`. `call!(m, ())` is a parse error ("empty tuple not allowed") | `do_p15.roc` | new |
| 40 | A handler that gives a tag that is not in the `err` of its `Rpc` does not compile. The error shows a pure lambda type `{ key: Str } -> [Err([Missing]), Ok(a)]` against `=> Try(Str, [Unknown])` | `do_p12.roc` | new |
| 41 | `Worker.new({ objects: [counter] })` is "Object.Class(NoRpc) against Object.AnyClass". Write `counter.erase()` | `do_p04.roc` | new |
| 42 | A `send!` or `send_json!` result as a statement: "second branch of this if ... Try({}, [Closed])". Write `_ =` | `do_p30.roc` | new |
| 43 | `Cache.default.put!(url, res)?` as a statement is "produces a value, but it's not being used" (the result is the response to send). `Ctx.wait_until!(cache.put(..))` is `Io(Response, ..)` against `Io({}, e)`. Use `put_after!` | `st_p32.roc` | new |
| 44 | `R2.from_headers(req.headers())` with no conditional header is no condition: the write is unconditional. A compare-and-swap route must refuse a request without `if-match` (428 in the topic) | docs (`MODULES.md` 5.3); the 428 guard and 412 on a wrong etag, 200 on the right quoted etag: `st_smoke_out/run_r2.toml` | new |
| 45 | `R2.to_response(obj)` is always status 200. A range response is `Response.from_body(206, ..)` with a `content-range` header | `platform/R2.roc`, `st_smoke_out/run_r2.toml` (`/head/a.txt` gives 206) | new |
| 46 | `Rpc.Infra` has 29 tags, and each costs 3 to 6 KB of wasm. An alias of the tags that the app uses (`Faults`) compiles with `?` on `Object.Cell.get_or!` | `do_p40.roc`; size from `MODULES.md` 1 | new |
| 47 | `x.get!(..) ?? default` gives the default for every `Err`, also a `KvErr` or a `StorageErr`. `get_or!` gives it for a missing key only | semantics; `get_or!` in `do_objects.roc` and `st_kv.roc` | new |
| 48 | `Object.cell` and a class with no `rpc` need no annotation to compile (`MODULES.md` 7 says to annotate a class with no `rpc`) | `do_p35.roc`, `do_p06.roc` | drift |
| 49 | A bare `?` on `key.metadata` (`Try(Metadata, [Missing])`) compiles on nightly-2026-10-19, so `key.metadata?.parse()?` works. `MODULES.md` 5.2 and section 15 say it does not (the old doc drift of FINDINGS-storage, `design_issues_tmp.md` X6) | `st_kv.roc`, `cfw_kv_cache.roc`, `st_smoke_out/run_kv_cache.toml` (`/owner/ann` gives `ann`) | drift |
| 50 | A misspelled handler name in `Object.class` is a compile error (extra record field), with a very long type in the message | `do_p36.roc` | new |
| 51 | Roc writes the fields of a record in name order, so `{ user, text }` reaches a JS client as `{"text":..,"user":..}` | `st_smoke_out/st_ws_client.mjs` | fact |
| 52 | An `Err` of `web_socket_message!` (here `msg.json()` on `not json`) is a log line `Room.webSocketMessage: failed: BadData(..)`, with no throw. The socket stays open | `st_smoke_out/st_ws_client.mjs`, `run_websockets.toml` | fact |
| 53 | A `list!` of KV gives one page. `page.next` is `More(cursor)` until the last | `platform/Kv.roc` (topic comment) | fact |

## Runs of the 7 topic apps (local `wrangler dev --local`, `st_smoke_out/`)

| Topic | Run | Result |
| --- | --- | --- |
| `cfw_objects` | `inc/a` twice, `show/a` twice | `1`, `2`, `count 2, hits 1`, `count 2, hits 2` (init!, SQL, cell, RPC, `set_alarm_in!`) |
| `cfw_websockets` | two clients on `room/r1`, one `ping`, one bad JSON, `echo`, a plain GET | relay with the sender skipped, `pong` with no event, echo, 426 |
| `cfw_rpc` | `admin/x` (entry point `fetch!` through a service binding) | 200 `admin`. The other Worker (`ledger-worker`) is not in the repo, so `balance` gives 500. The default entry point methods and `Rpc.forward` are tested by `conformance/` (`RpcRoutes.roc`, `RpcErrRoutes.roc`) |
| `cfw_d1` | users list, create twice, transfer batch, tuples, ids, session, `rows!` | 200, 201, 409, `15`, `2`, exact ids, bookmark header, columns |
| `cfw_r2` | put, get, range, conditional put (428, 412, 200), `R2.absent` (409, 201), generated stream, list, 304, delete after the response | all as in the comments |
| `cfw_kv_cache` | prefs get/put with default, owner, feed twice | default, 204, value, `ann`, second feed is a cache HIT |
| `cfw_queues` | `POST /` | 202, then `QUEUE mails 0/2` and `QUEUE crawl-jobs 0/1` (retries) |

## Doc drift to report to the platform

| Where | What |
| --- | --- |
| `MODULES.md` 5.1, "As built" row `rows!`, last sentence | A BLOB reads into `Cbor.Bytes` since roc-cbor 0.2.1 (finding 6) |
| `MODULES.md` 5.2 and 15, `MODULES.md:1650` | A bare `?` on `key.metadata` compiles (finding 49) |
| `MODULES.md` 7, "A class with no `rpc`" | No annotation needed for the cases tested (finding 48) |
| `D1.roc` doc of `all_tuples!` | Add that a NULL needs `Try(a, [Null])` there too (finding 21) |

## Fixed after the probes (2026-10-26)

Not committed, not released. `PLAN.md`, "Status of the v2 probe fixes (2026-10-26)", has the tests and the reverts. The probe `st_run` has the old behavior.

| # | State | How |
| --- | --- | --- |
| 21 | Text fixed | A NULL into a tuple item is `BadData("column 1 (from 0): NULL, read it into a Try(a, [Null]) item")`. The `all_tuples!` doc of `D1.roc` says it (drift row 4) |
| 28 | Fixed in part | One bare value is one parameter: `db.run!(sql, "ann")`, `5`, `Sql.null`, `Sql.blob(b)` are the same as `[x]` (`sqlParams` in `js/helpers.js` puts a value that is not an array or a map in a list). A `List(U8)` is still a list of parameters. The old tag form (`[Text("ann")]`, a bare `Int(5)`) is still `BadParam`, with a text that names the old form and the new form: `SQL parameter 0: Text("ann") is the old Sql tag form, write "ann"`. The compiler cannot refuse it: `params` is any `Cbor.Writable`, a `where` clause cannot leave out a type, and the builtin types take no platform method. A nominal parameter type would change each call. `(x)` is still not a tuple, but it is now one parameter, so it works |
| 30 | Text fixed | A NULL still reads only into `Try(a, [Null])`. `BadData` now names the rule: `column name: NULL, read it into a Try(a, [Null]) field`. The platform cannot read NULL into an optional field: JS cannot drop a NULL key, as a `Try(a, [Null])` field with no key is `MissingRequiredField` (`research/d1-traps/rows.roc`). A roc-cbor option is needed (`PLAN.md`) |
| 31 | Text fixed (`Bool` only) | A `Bool` field still does not read 0 and 1 (roc-cbor `parse_bool` reads only CBOR true and false). `BadData` now names the rule: `column b: the integer 1 does not fit the type, a boolean column gives 0 or 1: read it into an I64 or U8 field, not a Bool`. The other rules of row 31 do not change |
| 34 | Unchanged | Still two kinds (`PrimaryKey`, `Unique`), but the tag is flat now (core V17): `Err(Constraint({ kind: PrimaryKey, .. })) \| Err(Constraint({ kind: Unique, .. }))` |
