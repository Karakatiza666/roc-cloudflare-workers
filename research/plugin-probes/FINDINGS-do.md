# Findings: Durable Objects, WebSockets, RPC, Tcp

| # | Finding | How found | Error (short) |
| --- | --- | --- | --- |
| D1 | `Time.now_ms!({})` is a `U64`, and `Sql.Int` holds an `I64`. `U64` has no `to_i64`: use `to_i64_wrap` (or `_try`) | Storing a time in object SQL | `to_i64 method ... U64` missing method |
| D2 | `{ name }` with one field is a block that returns `name`, not a record. `socket.attach!({ name })` takes any `a`, so it compiles and stores a `Str`. The later `attachment!()` into `Member` is `BadData` at runtime. Write `{ name: name }` or `{ name, }` | do_2_ws compiled with `attach!({ name })`; do_3_rpc `call!(lookup, { key })` was refused because there the type is fixed | `This argument has the type: Str. But call! needs { key: Str }` |
| D3 | `Try` has no CBOR codec, so `Rpc(arg, Try(ret, err))` (the form that MODULES.md 8 recommends for typed errors) does not compile. Use a tag union reply: `Rpc(arg, [Found(Str), Unknown])` | do_3_rpc | `parser_for ... Try(Str, [Unknown])` missing method, and `encoder_for` on the `.on` side |
| D4 | All handlers of one `Object.class` share one error type `e`. A handler annotated `Try(Response, [])` (it only gives `Ok`) closes `e`, and a sibling handler that uses `?` no longer fits. Annotate with `Try(Response, _)` or leave it out | do_6_class_join | `type mismatch` on the whole class record; the two records differ only in `fetch! ... Try(Response, [])` |
| D5 | `self.sql!` reads into the type of the call. With no annotation and only `.len()` on the result, the row type is not known | do_7_sql_infer | `type not determined: Nothing in this program determines the type this parser_for method is called on` |
| D6 | Not a finding: a class with no `?` in any handler, a Worker `fetch!` that forwards to `rooms.named(n).fetch!(req)`, `s != from` on `Object.Socket`, `rooms.unique!()` and `Tcp.connect!` all compiled at the first try | do_1, do_2, do_5 | none |

Runtime rules (from MODULES.md 7, 8, 12 and Object.roc docs, measured in local workerd or on the edge by the platform):

| # | Rule | Source |
| --- | --- | --- |
| R1 | `set_alarm!` takes a time in ms since 1970 (`storage.setAlarm`), not a delay | Object.roc `set_alarm` (passes `time_ms` to `setAlarm`) |
| R2 | A class with no `alarm!` has no JS `alarm` method, so `set_alarm!` gives `StorageErr` (except in `init!`) | from MODULES.md 7 |
| R3 | `init!` runs at each start of the object (also after eviction or hibernation): it must be idempotent | from MODULES.md 7 |
| R4 | The class must be in `new_sqlite_classes`; a KV-backed class fails at its first event with the class name | from MODULES.md 7 |
| R5 | `export const X = objectClass("X")` must come before `export default makeHandler(...)`, else the load stops | from MODULES.md 3, API.md FO3 |
| R6 | An RPC call cannot carry a socket, a stream or a stub: forward the upgrade with `fetch!` | from MODULES.md 8, 12.1 |
| R7 | `Err(e)` of a callee reaches the caller as `RpcErr` with `Str.inspect(e)` as the message | from MODULES.md 8 |
| R8 | Storage calls with no wait between them are atomic; a wait (`Http.send!`, a call to another object) lets other events in | from MODULES.md 7 |
| R9 | `sql_run!` gives no last row id: use `insert ... returning id` with `sql!` | from MODULES.md 7 |
| R10 | An attachment is 16,384 bytes or less (`TooLarge`) | Object.roc `attach!` |
