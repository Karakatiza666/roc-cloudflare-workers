## Durable Objects (MODULES.md 7). Outside: a namespace and a stub are plain data (MC1); each call starts its program
## with `env[namespace]`, then the jurisdiction, then `getByName` or `get(idFromString(id))`. Inside: a class is a
## record of handlers (`class`), and `Object.Self` reaches the storage of the object that runs (the root `ctx`, a
## `DurableObjectState`). SQL, cells and `list!` are sync (`call!`, no wait, AQ3); the alarm calls and `delete_all!`
## wait once. SQLite-backed classes only (`new_sqlite_classes`): the shim checks it in the constructor.
## The sockets of the hibernation API (MODULES.md 12.1): `accept!` and the other socket calls of `Self` and `Socket` are
## sync (`call!`, no wait); the events `SocketMessage`, `SocketClose` and `SocketError` go to the handlers of the class.
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Io
import Js
import Body
import Request
import Response
import Rpc
import Sql
import SqlRules
import Remote
import WebSocket
import cbor.Cbor

Object :: { namespace : Str, jurisdiction : Str, target : [Named(Str), Id(Str)], location_hint : Str }.{

	## A namespace: the binding name and the class of its objects (`class_name` in the Wrangler config). The class is the
	## value of `Object.class`, so its name is written once. `script`: the Worker that has the class (`script_name`),
	## when it is not this Worker. For a class that this app does not have as a value, use `namespace_remote`.
	namespace : Str, { class : Object.Class, script ?: Str } -> Object.Namespace
	namespace = |binding, opts| Object.Namespace.{ binding, jurisdiction: "", class: opts.class.name, script: opts.?script ?? "" }

	## A namespace of a class that another Worker has (`script_name`): the app has the class name only, as text.
	namespace_remote : Str, { class : Str, script : Str } -> Object.Namespace
	namespace_remote = |binding, opts| Object.Namespace.{ binding, jurisdiction: "", class: opts.class, script: opts.script }

	## A namespace: the binding name, its jurisdiction ("" for none), its class and the Worker of the class ("" for
	## this Worker). Data.
	Namespace := { binding : Str, jurisdiction : Str, class : Str, script : Str }.{

		## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `object`, with
		## `class`, and `script` when the class is in another Worker. With no `script`, the shim checks at load that
		## the class is in `objects`.
		declare : Object.Namespace -> { name : Str, kind : Str, props : List((Str, Str)) }
		declare = |ns| {
			props = [("class", ns.class), ("script", ns.script)].keep_if(|(_, v)| v != "")
			{ name: ns.binding, kind: "object", props }
		}

		## A stub of the object with this name: `getByName(name)` runs in the program of each call.
		named : Object.Namespace, Str -> Object
		named = |ns, name| stub(ns, Named(name), Err(MissingField))

		named_with : Object.Namespace, Str, { location_hint ?: Object.Location } -> Object
		named_with = |ns, name, opts| stub(ns, Named(name), opts.?location_hint)

		## A stub of the object with this id (the text of `id.toString()`): `get(idFromString(id))`.
		from_id : Object.Namespace, Str -> Object
		from_id = |ns, id| stub(ns, Id(id), Err(MissingField))

		from_id_with : Object.Namespace, Str, { location_hint ?: Object.Location } -> Object
		from_id_with = |ns, id, opts| stub(ns, Id(id), opts.?location_hint)

		## `newUniqueId()`, sync (one `call!`). A throw is a crash: the type has no error.
		unique! : Object.Namespace => Object
		unique! = |ns| match unique_id!(ns, []) {
			Ok(id) => stub(ns, Id(id), Err(MissingField))
			Err(t) => crash "Object.unique!: ${t.name}: ${t.message}"
		}

		## `newUniqueId({ jurisdiction })`, sync. The Cloudflare docs recommend `jurisdiction` on the namespace.
		unique_with! : Object.Namespace, { jurisdiction ?: Object.Jurisdiction, location_hint ?: Object.Location } => Try(Object, [ObjectErr(Io.Thrown)])
		unique_with! = |ns, opts| {
			args = match opts.?jurisdiction {
				Ok(j) => [Lit(Obj([("jurisdiction", Text(jurisdiction_text(j)))]))]
				Err(_) => []
			}
			match unique_id!(ns, args) {
				Ok(id) => Ok(stub(ns, Id(id), opts.?location_hint))
				Err(t) => Err(ObjectErr(t))
			}
		}

		## `namespace.jurisdiction(j)`: data. The same name gives another object in another jurisdiction.
		jurisdiction : Object.Namespace, Object.Jurisdiction -> Object.Namespace
		jurisdiction = |ns, j| { ..ns, jurisdiction: jurisdiction_text(j) }
	}

	Jurisdiction : [Eu, Us, Fedramp]

	## `ApacNe` is "apac-ne". Best effort: only the first `get` of an object uses it (Cloudflare docs).
	Location : [Wnam, Enam, Sam, Weur, Eeur, Apac, ApacNe, ApacSe, Oc, Afr, Me]

	## `stub.fetch(request)`: a 101 response keeps its `web_socket`, so a Worker can give it to the client.
	fetch : Object, Request -> Io(Response, [ObjectErr(Io.Thrown)])
	fetch = |obj, req| {
		s = stub_ops(obj)
		Remote.fetch(s.ops, s.slot, req, |t| ObjectErr(t))
	}

	fetch! : Object, Request => Try(Response, [ObjectErr(Io.Thrown)])
	fetch! = |obj, req| Io.run!(fetch(obj, req))

	## `stub[method](arg)` with an `Rpc` constant: the reply is read to the RPC limit of Workers (32 MiB). An `Err` of
	## the callee is `Remote(err)`.
	call : Object, Rpc(arg, ret, err), arg -> Io(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call = |obj, m, a| {
		s = stub_ops(obj)
		Remote.call(s.ops, s.slot, m, a, Remote.rpc_max)
	}

	call! : Object, Rpc(arg, ret, err), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)]) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call! = |obj, m, a| Io.run!(call(obj, m, a))

	## The id of the object (`id.toString()`). The runtime makes the id of a named object from the name and the namespace
	## (and its jurisdiction), so a named object takes one `call!` (`idFromName`). A stub of an id needs no crossing.
	id! : Object => Try(Str, [ObjectErr(Io.Thrown)])
	id! = |obj| match obj.target {
		Id(id) => Ok(id)
		Named(name) => {
			ns = namespace_ops(obj)
			n = ns.len().to_u32_wrap()
			match Js.call!(ns.concat([Call(Slot(n - 1), "idFromName", [Lit(Text(name))]), Call(Slot(n), "toString", [])])) {
				Ok(Text(id)) => Ok(id)
				Ok(other) => crash "Object.id!: idFromName gave ${Str.inspect(other)}"
				Err(t) => Err(ObjectErr(t))
			}
		}
	}

	## The events of an object (API.md 10.1).
	Event : [
		Init,
		Fetch(Request),
		Alarm({ retry_count : U32, is_retry : Bool }),
		Rpc({ method : Str, arg : List(U8) }),
		SocketMessage(Object.Socket, WebSocket.Message),
		SocketClose(Object.Socket, WebSocket.Closed),
		SocketError(Object.Socket, Io.Thrown),
	]

	## A WebSocket that the object accepted with the hibernation API (MODULES.md 12.1). It holds a ref (MC13): good for
	## one event. `:=`, not `::`: `Entry` makes it from the socket of an event. Each call is one `call!` (no wait).
	Socket := { ref : Js.Ref }.{

		## The same JS socket has the same ref in a task (API.md RS1), so `peer == socket` finds the sender in
		## `self.sockets!()`.
		is_eq : Object.Socket, Object.Socket -> Bool
		is_eq = |a, b| a.ref == b.ref

		send! : Object.Socket, WebSocket.Message => Try({}, [Closed])
		send! = |sock, msg| Remote.socket_send!(sock.ref, frame(msg))

		## A value that JSON cannot show (a `NaN` in an `F64`) is `BadData`, and nothing is sent.
		send_json! : Object.Socket, a => Try({}, [Closed, BadData(Str)]) where [a.Json.Encodable(enc)]
		send_json! = |sock, value| match Json.to_str_try(value) {
			Ok(text) => Remote.socket_send!(sock.ref, Text(text)).map_err(|_| Closed)
			Err(e) => Err(BadData(Str.inspect(e)))
		}

		close! : Object.Socket, U16, Str => {}
		close! = |sock, code, reason| Remote.socket_close!(sock.ref, code, reason)

		## `ctx.getTags(ws)`: the tags of `accept_with!`.
		tags! : Object.Socket => List(Str)
		tags! = |sock| match Js.call!([Call(Root("ctx"), "getTags", [Lit(Ref(sock.ref))])]) {
			Ok(Arr(items)) => items.map(
				|t| match t {
					Text(x) => x
					other => crash "Object.Socket.tags!: a tag is ${Str.inspect(other)}"
				},
			)
			Ok(other) => crash "Object.Socket.tags!: getTags gave ${Str.inspect(other)}"
			Err(t) => crash "Object.Socket.tags!: ${t.name}: ${t.message}"
		}

		## `ctx.getWebSocketAutoResponseTimestamp(ws)`: the time of the last auto response, or `NotFound`.
		auto_response_ms! : Object.Socket => Try(U64, [NotFound])
		auto_response_ms! = |sock| match Js.call!([Call(Root("ctx"), "getWebSocketAutoResponseTimestamp", [Lit(Ref(sock.ref))])]) {
			Ok(Int(t)) => Ok(t.to_u64_try() ?? 0)
			Ok(Num(f)) => Ok(f.to_u64_try() ?? 0)
			Ok(_) => Err(NotFound)
			Err(t) => crash "Object.Socket.auto_response_ms!: ${t.name}: ${t.message}"
		}
	}

	## The object that runs: its class and its id. Each storage function reaches `ctx.storage` of the task.
	Self :: { class : Str, id : Str }.{

		## `ctx.id.toString()`: pure, the event carries it.
		id : Object.Self -> Str
		id = |self| self.id

		## Rows as the type of the call (`rows : List(Row)`), to `Body.default_max` bytes of CBOR: `sql.exec(...).toArray()`,
		## then `pf.pack`. The integer rules of `D1.all!` (MODULES.md 5.1): `CAST(x AS TEXT)` reads into an `I64`.
		sql! : Object.Self, Str, params => Try(rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Readable(errs), params.Cbor.Writable]
		sql! = |self, sql, params| sql_typed!(self, sql, Cbor.encode(params), Body.default_max)

		sql_with! : Object.Self, Str, params, { max_bytes : U64 } => Try(rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Readable(errs), params.Cbor.Writable]
		sql_with! = |self, sql, params, opts| sql_typed!(self, sql, Cbor.encode(params), opts.max_bytes)

		## A write: `rowsRead` and `rowsWritten` of the cursor (an object cursor has no `changes` and no last row id).
		sql_run! : Object.Self, Str, params => Try(Object.SqlInfo, [SqlErr(Io.Thrown), Constraint(Sql.Constraint)]) where [params.Cbor.Writable]
		sql_run! = |_self, sql, params| match Js.call!(sql_ops(sql, Cbor.encode(params)).concat([Call(Slot(2), "toArray", []), Fields(Slot(2), ["rowsRead", "rowsWritten"])])) {
			Ok(Obj(fields)) => match (field(fields, "rowsRead"), field(fields, "rowsWritten")) {
				(Int(r), Int(w)) => Ok({ rows_read: r.to_u64_try() ?? 0, rows_written: w.to_u64_try() ?? 0 })
				other => Err(SqlErr({ name: "BadData", message: "the cursor gave ${Str.inspect(other)}" }))
			}
			Ok(other) => Err(SqlErr({ name: "BadData", message: "the cursor gave ${Str.inspect(other)}" }))
			Err(t) => match sql_error(t) {
				Constraint(c) => Err(Constraint(c))
				SqlErr(e) => Err(SqlErr(e))
				TooLarge => Err(SqlErr(t))
			}
		}

		## Rows with no types: the column names, then the values (`raw()`), to `Body.default_max` bytes.
		sql_rows! : Object.Self, Str, params => Try(Sql.Rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), TooLarge]) where [params.Cbor.Writable]
		sql_rows! = |self, sql, params| sql_raw!(self, sql, Cbor.encode(params), Body.default_max)

		sql_rows_with! : Object.Self, Str, params, { max_bytes : U64 } => Try(Sql.Rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), TooLarge]) where [params.Cbor.Writable]
		sql_rows_with! = |self, sql, params, opts| sql_raw!(self, sql, Cbor.encode(params), opts.max_bytes)

		## `storage.setAlarm(epoch_ms)`: a promise, one wait. `epoch_ms` is a time of the clock (`Time.now_ms!`), not a
		## delay: use `set_alarm_in!` for a delay. A class with no `alarm!` has no `alarm` method in JS, so Workers
		## throws: `StorageErr`.
		set_alarm_at : Object.Self, U64 -> Io({}, [StorageErr(Io.Thrown)])
		set_alarm_at = |_self, epoch_ms| Io.new(
			[Get(Root("ctx"), "storage"), Call(Slot(0), "setAlarm", [Lit(Int(epoch_ms.to_i64_try() ?? I64.highest))])],
			|r| r.map_ok(|_| {}).map_err(|t| StorageErr(t)),
		)

		set_alarm_at! : Object.Self, U64 => Try({}, [StorageErr(Io.Thrown)])
		set_alarm_at! = |self, epoch_ms| Io.run!(set_alarm_at(self, epoch_ms))

		## `storage.setAlarm(Date.now() + delay_ms)`: the alarm fires `delay_ms` after the call. `pf.alarmIn` reads the
		## clock in the same program.
		set_alarm_in : Object.Self, U64 -> Io({}, [StorageErr(Io.Thrown)])
		set_alarm_in = |_self, delay_ms| Io.new(
			[Get(Root("ctx"), "storage"), Call(Root("pf"), "alarmIn", [Slot(0), Lit(Int(delay_ms.to_i64_try() ?? I64.highest))])],
			|r| r.map_ok(|_| {}).map_err(|t| StorageErr(t)),
		)

		set_alarm_in! : Object.Self, U64 => Try({}, [StorageErr(Io.Thrown)])
		set_alarm_in! = |self, delay_ms| Io.run!(set_alarm_in(self, delay_ms))

		## `storage.getAlarm()`: the time in ms (absolute, like `set_alarm_at!`), or `NotFound`.
		get_alarm : Object.Self -> Io(U64, [NotFound, StorageErr(Io.Thrown)])
		get_alarm = |_self| Io.new(
			[Get(Root("ctx"), "storage"), Call(Slot(0), "getAlarm", [])],
			|r| match r {
				Ok(Int(t)) => Ok(t.to_u64_try() ?? 0)
				Ok(Num(f)) => Ok(f.to_u64_try() ?? 0)
				Ok(_) => Err(NotFound)
				Err(t) => Err(StorageErr(t))
			},
		)

		get_alarm! : Object.Self => Try(U64, [NotFound, StorageErr(Io.Thrown)])
		get_alarm! = |self| Io.run!(get_alarm(self))

		delete_alarm : Object.Self -> Io({}, [StorageErr(Io.Thrown)])
		delete_alarm = |_self| Io.new([Get(Root("ctx"), "storage"), Call(Slot(0), "deleteAlarm", [])], |r| r.map_ok(|_| {}).map_err(|t| StorageErr(t)))

		delete_alarm! : Object.Self => Try({}, [StorageErr(Io.Thrown)])
		delete_alarm! = |self| Io.run!(delete_alarm(self))

		## All storage of the object: the SQL tables, the cells and the alarm. `deleteAlarm`, then `deleteAll`, in one
		## program: with a compatibility date before 2026-02-24, `deleteAll` keeps the alarm (Cloudflare docs).
		delete_all : Object.Self -> Io({}, [StorageErr(Io.Thrown)])
		delete_all = |_self| Io.new(
			[Get(Root("ctx"), "storage"), Call(Slot(0), "deleteAlarm", []), Call(Slot(0), "deleteAll", [])],
			|r| r.map_ok(|_| {}).map_err(|t| StorageErr(t)),
		)

		delete_all! : Object.Self => Try({}, [StorageErr(Io.Thrown)])
		delete_all! = |self| Io.run!(delete_all(self))

		## The keys of the sync KV storage (the cells), in UTF-8 order: `storage.kv.list()`. The values stay in JS. All keys
		## to `Body.default_max` bytes (MC11): `TooLarge` past it.
		list! : Object.Self => Try(List(Str), [TooLarge, StorageErr(Io.Thrown)])
		list! = |self| self.list_with!({})

		list_with! : Object.Self, { prefix ?: Str, start ?: Str, start_after ?: Str, end ?: Str, limit ?: U32, reverse ?: Bool } => Try(List(Str), [TooLarge, StorageErr(Io.Thrown)])
		list_with! = |_self, opts| {
			text_opt = |acc, name, v| match v {
				Ok(s) => acc.append((name, Text(s)))
				Err(_) => acc
			}
			o1 = []
				|> text_opt("prefix", opts.?prefix)
				|> text_opt("start", opts.?start)
				|> text_opt("startAfter", opts.?start_after)
				|> text_opt("end", opts.?end)
			o2 = match opts.?limit {
				Ok(n) => o1.append(("limit", Int(n.to_i64())))
				Err(_) => o1
			}
			o3 = match opts.?reverse {
				Ok(b) => o2.append(("reverse", Bool(b)))
				Err(_) => o2
			}
			ops = [
				Get(Root("ctx"), "storage"),
				Get(Slot(0), "kv"),
				Call(Slot(1), "list", [Lit(Obj(o3))]),
				Call(Root("pf"), "keys", [Slot(2), Lit(Int(limit(Body.default_max)))]),
			]
			match Js.call!(ops) {
				Ok(Arr(keys)) => Ok(
					keys.map(
						|k| match k {
							Text(s) => s
							other => crash "Object.list!: a key is ${Str.inspect(other)}"
						},
					),
				)
				Ok(other) => crash "Object.list!: pf.keys gave ${Str.inspect(other)}"
				Err(t) => if (t.name == "TooLarge") Err(TooLarge) else Err(StorageErr(t))
			}
		}

		## The hibernation API (MODULES.md 12.1): `new WebSocketPair()`, `ctx.acceptWebSocket(server)` and a 101 response
		## with the client end, in one `call!`. The object can leave memory while the socket is open: its messages come
		## as events. `NotUpgrade` when the request has no `Upgrade: websocket`.
		accept! : Object.Self, Request => Try({ socket : Object.Socket, response : Response }, [NotUpgrade])
		accept! = |self, req| match accept_tags!(self, req, []) {
			Ok(r) => Ok(r)
			Err(NotUpgrade) => Err(NotUpgrade)
			Err(TooLarge) => crash "Object.Self.accept!: acceptWebSocket threw with no tags"
		}

		## `tags`: 10 or less, 256 characters or less each (Workers), else `TooLarge`. `sockets_with!` finds them.
		accept_with! : Object.Self, Request, { tags ?: List(Str) } => Try({ socket : Object.Socket, response : Response }, [NotUpgrade, TooLarge])
		accept_with! = |self, req, opts| accept_tags!(self, req, opts.?tags ?? [])

		## `ctx.getWebSockets()`: the open sockets of the object.
		sockets! : Object.Self => List(Object.Socket)
		sockets! = |_self| sockets_of!([])

		## `ctx.getWebSockets(tag)`: the open sockets with the tag.
		sockets_with! : Object.Self, { tag : Str } => List(Object.Socket)
		sockets_with! = |_self, opts| sockets_of!([Lit(Text(opts.tag))])

		## Sends the message to each open socket of the object. A closed socket is skipped. Use `broadcast_with!` for the
		## number of sockets that got it.
		broadcast! : Object.Self, WebSocket.Message => {}
		broadcast! = |_self, msg| {
			_ = send_each!(sockets_of!([]), msg)
			{}
		}

		## `broadcast!` of a value as JSON text, like `Object.Socket.send_json!`. A value that JSON cannot show (a `NaN`
		## in an `F64`) is `BadData`, and nothing is sent.
		broadcast_json! : Object.Self, a => Try({}, [BadData(Str)]) where [a.Json.Encodable(enc)]
		broadcast_json! = |self, value| match Json.to_str_try(value) {
			Ok(text) => Ok(self.broadcast!(Text(text)))
			Err(e) => Err(BadData(Str.inspect(e)))
		}

		## `broadcast!` that gives the number of sockets that got the message. `tag`: the sockets with the tag only,
		## else all open sockets (`broadcast_with!({}, msg)`).
		broadcast_with! : Object.Self, { tag ?: Str }, WebSocket.Message => U64
		broadcast_with! = |_self, opts, msg| {
			filter = match opts.?tag {
				Ok(t) => [Lit(Text(t))]
				Err(_) => []
			}
			send_each!(sockets_of!(filter), msg)
		}

		## `broadcast_with!` of a value as JSON text. `BadData` as for `broadcast_json!`: nothing is sent.
		broadcast_json_with! : Object.Self, { tag ?: Str }, a => Try(U64, [BadData(Str)]) where [a.Json.Encodable(enc)]
		broadcast_json_with! = |self, opts, value| match Json.to_str_try(value) {
			Ok(text) => Ok(self.broadcast_with!(opts, Text(text)))
			Err(e) => Err(BadData(Str.inspect(e)))
		}

		## `ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(request, response))`: Workers answers the text
		## `request` with `response` and sends no event, so the object can stay asleep. 2,048 characters or less each
		## (Workers), else `TooLarge`.
		set_auto_response! : Object.Self, { request : Str, response : Str } => Try({}, [TooLarge])
		set_auto_response! = |_self, pair| match Js.call!([New(Root("global"), "WebSocketRequestResponsePair", [Lit(Text(pair.request)), Lit(Text(pair.response))]), Call(Root("ctx"), "setWebSocketAutoResponse", [Slot(0)])]) {
			Ok(_) => Ok({})
			Err(_) => Err(TooLarge)
		}

		## `ctx.setWebSocketAutoResponse()`: no auto response.
		clear_auto_response! : Object.Self => {}
		clear_auto_response! = |_self| match Js.call!([Call(Root("ctx"), "setWebSocketAutoResponse", [])]) {
			Ok(_) => {}
			Err(t) => crash "Object.Self.clear_auto_response!: ${t.name}: ${t.message}"
		}
	}

	## What a SQL cursor of a Durable Object gives (rowsRead, rowsWritten). D1 also gives changes and last_row_id (Sql.Info).
	SqlInfo : { rows_read : U64, rows_written : U64 }

	## A class of Durable Objects: a record of handlers, all optional (MODULES.md 7). Each handler has its own error
	## type: an `Err(e)` becomes a log line with `Str.inspect(e)` (the outcome `Failed`). The name is the name of the JS
	## export (`export const Counter = objectClass("Counter")`) and of the Wrangler config.
	class : Str,
	{
		init! ?: Object.Self => Try({}, e1),
		fetch! ?: Object.Self, Request => Try(Response, e2),
		rpc ?: List(Rpc.Handler(Object.Self)),
		alarm! ?: Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, e3),
		web_socket_message! ?: Object.Self, Object.Socket, WebSocket.Message => Try({}, e4),
		web_socket_close! ?: Object.Self, Object.Socket, WebSocket.Closed => Try({}, e5),
		web_socket_error! ?: Object.Self, Object.Socket, Io.Thrown => Try({}, e6),
	} -> Object.Class
	class = |name, h| {
		name,
		handlers: [
			("init", h.?init!.is_ok()),
			("fetch", h.?fetch!.is_ok()),
			("alarm", h.?alarm!.is_ok()),
			("webSocketMessage", h.?web_socket_message!.is_ok()),
			("webSocketClose", h.?web_socket_close!.is_ok()),
			("webSocketError", h.?web_socket_error!.is_ok()),
		].keep_if(|(_, present)| present).map(|(n, _)| n),
		methods: (h.?rpc ?? []).map(|m| m.name),
		run!: |id, ev| {
			self = Object.Self.{ class: name, id }
			match ev {
				Init => match h.?init! {
					Ok(f!) => done(f!(self))
					Err(MissingField) => Unhandled
				}
				Fetch(req) => match h.?fetch! {
					Ok(f!) => match f!(self, req) {
						Ok(res) => Respond(res)
						Err(e) => Failed(Str.inspect(e))
					}
					Err(MissingField) => Unhandled
				}
				Alarm(info) => match h.?alarm! {
					Ok(f!) => done(f!(self, info))
					Err(MissingField) => Unhandled
				}
				Rpc({ method, arg }) => match (h.?rpc ?? []).find_first(|m| m.name == method) {
					Ok(m) => {
						run! = m.run!
						match run!(self, arg) {
							Ok(bytes) => Reply(Packed(bytes))
							Err(text) => Failed(text)
						}
					}
					Err(_) => Unhandled
				}
				# The hibernation API (MODULES.md 12.1).
				SocketMessage(sock, msg) => match h.?web_socket_message! {
					Ok(f!) => done(f!(self, sock, msg))
					Err(MissingField) => Unhandled
				}
				SocketClose(sock, closed) => match h.?web_socket_close! {
					Ok(f!) => done(f!(self, sock, closed))
					Err(MissingField) => Unhandled
				}
				SocketError(sock, thrown) => match h.?web_socket_error! {
					Ok(f!) => done(f!(self, sock, thrown))
					Err(MissingField) => Unhandled
				}
			}
		},
	}

	## A class with its types erased: the handlers that its JS class has (`init`, `fetch`, `alarm`, `webSocketMessage`,
	## `webSocketClose`, `webSocketError`) and its RPC methods
	## (the manifest, API.md AQ10), and the function that runs an event for the object of an id.
	Class : { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled] }

	## A typed value in the sync KV storage of the object (MODULES.md 9): CBOR bytes under one key. A constant (WR1).
	cell : Str -> Object.Cell(a) where [a.Cbor.Writable, a.Cbor.Readable(errs)]
	cell = |key| Object.Cell.{ key, write: |v| Cbor.encode(v), read: |bytes| Cbor.parse(bytes).map_err(|e| Str.inspect(e)) }

	## Each function takes the `Object.Self` and is one `call!` (no wait).
	Cell(a) :: { key : Str, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{

		## `storage.kv.get(key)`: `NotFound` when there is no value.
		get! : Object.Cell(a), Object.Self => Try(a, [NotFound, BadData(Str), StorageErr(Io.Thrown)])
		get! = |c, _self| {
			read = c.read
			match Js.call!(kv_ops("get", [Lit(Text(c.key))])) {
				Ok(Bytes(bytes)) => read(bytes).map_err(|m| BadData(m))
				Ok(Undefined) | Ok(Null) => Err(NotFound)
				Ok(other) => Err(BadData("the cell ${c.key} holds ${Str.inspect(other)}, not CBOR bytes"))
				Err(t) => Err(StorageErr(t))
			}
		}

		## `get!`, and `default` for a cell that has no value. The other errors stay.
		get_or! : Object.Cell(a), Object.Self, a => Try(a, [BadData(Str), StorageErr(Io.Thrown)])
		get_or! = |c, self, default| match c.get!(self) {
			Ok(v) => Ok(v)
			Err(NotFound) => Ok(default)
			Err(BadData(m)) => Err(BadData(m))
			Err(StorageErr(t)) => Err(StorageErr(t))
		}

		## `get!` that gives a missing value as `Ok(Err(NotFound))`, so the error type of the caller has no `NotFound`:
		## `match c.find!(self)? { Ok(v) => ..., Err(NotFound) => ... }`.
		find! : Object.Cell(a), Object.Self => Try(Try(a, [NotFound]), [BadData(Str), StorageErr(Io.Thrown)])
		find! = |c, self| match c.get!(self) {
			Ok(v) => Ok(Ok(v))
			Err(NotFound) => Ok(Err(NotFound))
			Err(BadData(m)) => Err(BadData(m))
			Err(StorageErr(t)) => Err(StorageErr(t))
		}

		## `storage.kv.put(key, bytes)`.
		set! : Object.Cell(a), Object.Self, a => Try({}, [StorageErr(Io.Thrown)])
		set! = |c, _self, v| {
			write = c.write
			Js.call!(kv_ops("put", [Lit(Text(c.key)), Lit(Bytes(write(v)))])).map_ok(|_| {}).map_err(|t| StorageErr(t))
		}

		## `storage.kv.delete(key)`. A key with no value is `Ok` too.
		delete! : Object.Cell(a), Object.Self => Try({}, [StorageErr(Io.Thrown)])
		delete! = |c, _self| Js.call!(kv_ops("delete", [Lit(Text(c.key))])).map_ok(|_| {}).map_err(|t| StorageErr(t))
	}

	## A typed attachment of a socket (MODULES.md 12.1): CBOR bytes in `ws.serializeAttachment`. A constant (WR1), like
	## `Object.Cell`: the same constant writes and reads, so the stored type and the read type are one. A socket has one
	## attachment slot: two constants on one socket share it. `name` shows in the `BadData` text only.
	attachment : Str -> Object.Attachment(a) where [a.Cbor.Writable, a.Cbor.Readable(errs)]
	attachment = |name| Object.Attachment.{ name, write: |v| Cbor.encode(v), read: |bytes| Cbor.parse(bytes).map_err(|e| Str.inspect(e)) }

	Attachment(a) :: { name : Str, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{

		## `ws.serializeAttachment(bytes)`: it stays while the object sleeps. Workers refuses more than 16,384 bytes:
		## `TooLarge`.
		set! : Object.Attachment(a), Object.Socket, a => Try({}, [TooLarge])
		set! = |att, sock, value| {
			write = att.write
			match Js.call!([Call(Ref(sock.ref), "serializeAttachment", [Lit(Bytes(write(value)))])]) {
				Ok(_) => Ok({})
				Err(_) => Err(TooLarge)
			}
		}

		## `ws.deserializeAttachment()`. `NotFound` when there is none.
		get! : Object.Attachment(a), Object.Socket => Try(a, [NotFound, BadData(Str)])
		get! = |att, sock| {
			read = att.read
			match Js.call!([Call(Ref(sock.ref), "deserializeAttachment", [])]) {
				Ok(Bytes(bytes)) => read(bytes).map_err(|m| BadData("the attachment ${att.name}: ${m}"))
				Ok(Null) | Ok(Undefined) => Err(NotFound)
				Ok(other) => Err(BadData("the attachment ${att.name} is ${Str.inspect(other)}, not CBOR bytes"))
				Err(t) => Err(BadData("${t.name}: ${t.message}"))
			}
		}
	}
}

stub : Object.Namespace, [Named(Str), Id(Str)], Try(Object.Location, [MissingField]) -> Object
stub = |ns, target, hint| Object.{
	namespace: ns.binding,
	jurisdiction: ns.jurisdiction,
	target,
	location_hint: hint.map_ok(location_text) ?? "",
}

## `env[namespace]`, then `jurisdiction(j)` when the namespace has one. The namespace is in the last slot.
namespace_ops : Object -> List(Js.Op)
namespace_ops = |obj|
	if obj.jurisdiction == "" {
		[Get(Root("env"), obj.namespace)]
	} else {
		[Get(Root("env"), obj.namespace), Call(Slot(0), "jurisdiction", [Lit(Text(obj.jurisdiction))])]
	}

## The ops that make the stub, and its slot: `getByName(name, opts)`, or `get(idFromString(id), opts)`.
stub_ops : Object -> { ops : List(Js.Op), slot : U32 }
stub_ops = |obj| {
	ns = namespace_ops(obj)
	n = ns.len().to_u32_wrap()
	opts = if (obj.location_hint == "") [] else [Lit(Obj([("locationHint", Text(obj.location_hint))]))]
	match obj.target {
		Named(name) => { ops: ns.append(Call(Slot(n - 1), "getByName", [Lit(Text(name))].concat(opts))), slot: n }
		Id(id) => { ops: ns.concat([Call(Slot(n - 1), "idFromString", [Lit(Text(id))]), Call(Slot(n - 1), "get", [Slot(n)].concat(opts))]), slot: n + 1 }
	}
}

unique_id! : Object.Namespace, List(Js.Arg) => Try(Str, Io.Thrown)
unique_id! = |ns, args| {
	start = if (ns.jurisdiction == "") [Get(Root("env"), ns.binding)] else [Get(Root("env"), ns.binding), Call(Slot(0), "jurisdiction", [Lit(Text(ns.jurisdiction))])]
	n = start.len().to_u32_wrap()
	match Js.call!(start.concat([Call(Slot(n - 1), "newUniqueId", args), Call(Slot(n), "toString", [])])) {
		Ok(Text(id)) => Ok(id)
		Ok(other) => crash "Object.unique!: newUniqueId gave ${Str.inspect(other)}"
		Err(t) => Err(t)
	}
}

jurisdiction_text : Object.Jurisdiction -> Str
jurisdiction_text = |j| match j {
	Eu => "eu"
	Us => "us"
	Fedramp => "fedramp"
}

location_text : Object.Location -> Str
location_text = |l| match l {
	Wnam => "wnam"
	Enam => "enam"
	Sam => "sam"
	Weur => "weur"
	Eeur => "eeur"
	Apac => "apac"
	ApacNe => "apac-ne"
	ApacSe => "apac-se"
	Oc => "oc"
	Afr => "afr"
	Me => "me"
}

## `ctx.storage.sql.exec(sql, ...params)` as `pf.sqlExec(sql_api, sql, params)` (js/helpers.js): the cursor is in slot 2.
## `params` is the CBOR of an array, checked as for D1 (MODULES.md 5.1): object SQL takes no `BigInt` either
## ("Cannot convert a BigInt value to a number", PLAN.md 8f, part 1).
sql_ops : Str, List(U8) -> List(Js.Op)
sql_ops = |sql, params| [
	Get(Root("ctx"), "storage"),
	Get(Slot(0), "sql"),
	Call(Root("pf"), "sqlExec", [Slot(1), Lit(Text(sql)), Lit(Packed(params))]),
]

sql_typed! : Object.Self, Str, List(U8), U64 => Try(rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Readable(errs)]
sql_typed! = |_self, sql, params, max| match Js.call!(sql_ops(sql, params).concat([Call(Slot(2), "toArray", []), Call(Root("pf"), "pack", [Slot(3), Lit(Int(limit(max)))])])) {
	Ok(Packed(bytes)) => match SqlRules.typed(bytes) {
		Ok(v) => Ok(v)
		Err(BadData(text)) => Err(BadData(text))
	}
	Ok(other) => crash "Object.Self.sql!: pf.pack gave ${Str.inspect(other)}"
	Err(t) => match sql_error(t) {
		Constraint(c) => Err(Constraint(c))
		SqlErr(e) => Err(SqlErr(e))
		TooLarge => Err(TooLarge)
	}
}

sql_raw! : Object.Self, Str, List(U8), U64 => Try(Sql.Rows, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
sql_raw! = |_self, sql, params, max| {
	ops = sql_ops(sql, params).concat([
		Get(Slot(2), "columnNames"),
		Call(Slot(2), "raw", []),
		Get(Root("global"), "Array"),
		Call(Slot(5), "from", [Slot(4)]),
		Record([("columns", Slot(3)), ("rows", Slot(6))]),
		Call(Root("pf"), "limit", [Slot(7), Lit(Int(limit(max)))]),
	])
	match Js.call!(ops) {
		Ok(Obj(fields)) => match (field(fields, "columns"), field(fields, "rows")) {
			(Arr(names), Arr(rows)) => Ok({ columns: names.map(SqlRules.column_name), rows: rows.map(SqlRules.row_of) })
			other => crash "Object.Self.sql_rows!: the cursor gave ${Str.inspect(other)}"
		}
		Ok(other) => crash "Object.Self.sql_rows!: the cursor gave ${Str.inspect(other)}"
		Err(t) => match sql_error(t) {
			Constraint(c) => Err(Constraint(c))
			SqlErr(e) => Err(SqlErr(e))
			TooLarge => Err(TooLarge)
		}
	}
}

## MC9 and MC11: the limit of `pf.pack` and `pf.limit` is `TooLarge`, a constraint failure is `Constraint` (the texts of
## D1 with no `D1_ERROR: `, MODULES.md 5.1), each other throw `SqlErr`.
sql_error : Io.Thrown -> [SqlErr(Io.Thrown), Constraint(Sql.Constraint), TooLarge]
sql_error = |t|
	if t.name == "TooLarge" {
		TooLarge
	} else {
		match SqlRules.constraint_of(t.message) {
			Ok(c) => Constraint(c)
			Err(NotConstraint) => SqlErr(t)
		}
	}

## `ctx.storage.kv[method](...args)`.
kv_ops : Str, List(Js.Arg) -> List(Js.Op)
kv_ops = |method, args| [Get(Root("ctx"), "storage"), Get(Slot(0), "kv"), Call(Slot(1), method, args)]

done : Try({}, e) -> [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled]
done = |r| match r {
	Ok({}) => Done
	Err(e) => Failed(Str.inspect(e))
}

## A limit as the `Int` of a program (I64).
limit : U64 -> I64
limit = |n| n.to_i64_try() ?? I64.highest

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

## A frame as the value of `ws.send(data)`.
frame : WebSocket.Message -> Js
frame = |msg| match msg {
	Text(t) => Text(t)
	Bytes(b) => Bytes(b)
}

## `accept!` with tags: a throw of `acceptWebSocket` (more than 10 tags, a tag too long) is `TooLarge`.
accept_tags! : Object.Self, Request, List(Str) => Try({ socket : Object.Socket, response : Response }, [NotUpgrade, TooLarge])
accept_tags! = |_self, req, tags|
	if !WebSocket.is_upgrade(req) {
		Err(NotUpgrade)
	} else {
		ops = [
			New(Root("global"), "WebSocketPair", []),
			Get(Slot(0), "0"),
			Get(Slot(0), "1"),
			Call(Root("ctx"), "acceptWebSocket", [Slot(2), Lit(Arr(tags.map(|t| Text(t))))]),
			Array([Slot(1), Slot(2)]),
		]
		match Js.call!(ops) {
			Ok(Arr([Ref(client), Ref(server)])) => Ok({ socket: Object.Socket.{ ref: server }, response: Response.from_status(101).with_web_socket(client) })
			Ok(other) => crash "Object.Self.accept!: the pair is ${Str.inspect(other)}"
			Err(_) => Err(TooLarge)
		}
	}

## `ctx.getWebSockets(...args)` as sockets.
sockets_of! : List(Js.Arg) => List(Object.Socket)
sockets_of! = |args| match Js.call!([Call(Root("ctx"), "getWebSockets", args)]) {
	Ok(Arr(items)) => items.map(
		|v| match v {
			Ref(r) => Object.Socket.{ ref: r }
			other => crash "Object.Self.sockets!: a socket is ${Str.inspect(other)}"
		},
	)
	Ok(other) => crash "Object.Self.sockets!: getWebSockets gave ${Str.inspect(other)}"
	Err(t) => crash "Object.Self.sockets!: ${t.name}: ${t.message}"
}

## `send!` to each socket. A closed socket does not count.
send_each! : List(Object.Socket), WebSocket.Message => U64
send_each! = |socks, msg| {
	var $sent = 0
	for sock in socks {
		match sock.send!(msg) {
			Ok(_) => {
				$sent = $sent + 1
			}
			Err(Closed) => {}
		}
	}
	$sent
}
