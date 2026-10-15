import Io
import Js
import Body
import Cbor
import Rpc
import Sql
import Request
import Response
import WebSocket

## A Durable Object stub: plain data, like a binding (API.md 6.3). `id` is "name:<name>" or "id:<id>".
Object :: { ns : Str, jurisdiction : Str, id : Str, hint : Str }.{
	namespace : Str -> Object.Namespace
	namespace = |binding| { binding, jurisdiction: "" }

	Namespace := { binding : Str, jurisdiction : Str }.{
		## `getByName` runs in the program of each call, so this needs no crossing.
		named : Object.Namespace, Str -> Object
		named = |ns, name| ns.named_with(name, {})

		named_with : Object.Namespace, Str, { location_hint ?: Object.Location } -> Object
		named_with = |ns, name, opts| stub(ns, "name:${name}", opts.?location_hint)

		from_id : Object.Namespace, Str -> Object
		from_id = |ns, id| ns.from_id_with(id, {})

		from_id_with : Object.Namespace, Str, { location_hint ?: Object.Location } -> Object
		from_id_with = |ns, id, opts| stub(ns, "id:${id}", opts.?location_hint)

		## `newUniqueId`, sync.
		unique! : Object.Namespace => Object
		unique! = |ns| ns.unique_with!({}) ?? stub(ns, "id:", Err(MissingField))

		unique_with! : Object.Namespace, { jurisdiction ?: Object.Jurisdiction, location_hint ?: Object.Location } => Try(Object, [ObjectErr(Io.Thrown)])
		unique_with! = |ns, opts| {
			juris = opts.?jurisdiction.map_ok(jurisdiction_text) ?? ns.jurisdiction
			id : Str
			id = Io.run!(Io.tree(["do.unique", ns.binding, juris], |t| ObjectErr(t)))?
			Ok(stub(ns, "id:${id}", opts.?location_hint))
		}

		## `namespace.jurisdiction(j)`: data.
		jurisdiction : Object.Namespace, Object.Jurisdiction -> Object.Namespace
		jurisdiction = |ns, j| { ..ns, jurisdiction: jurisdiction_text(j) }
	}

	Jurisdiction : [Eu, Us, Fedramp]

	Location : [Wnam, Enam, Sam, Weur, Eeur, Apac, ApacNe, ApacSe, Oc, Afr, Me]

	## The id: one `call!` for a named object (`idFromName`), none for an id.
	id! : Object => Try(Str, [ObjectErr(Io.Thrown)])
	id! = |obj| {
		Object.{ ns, jurisdiction, id, .. } = obj
		if id.starts_with("name:") Io.run!(Io.tree(["object.id", ns, jurisdiction, id.drop_prefix("name:")], |t| ObjectErr(t))) else Ok(id.drop_prefix("id:"))
	}

	call : Object, Rpc(arg, ret), arg -> Io(ret, [RpcErr(Io.Thrown), BadData(Str)])
		where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	call = |obj, m, arg| {
		Object.{ ns, id, .. } = obj
		m.call(["object", ns, id], arg)
	}

	## `stub.fetch(request)`. A 101 response keeps its `web_socket`, so a Worker can give it to the client.
	fetch! : Object, Request => Try(Response, [ObjectErr(Io.Thrown)])
	fetch! = |obj, _req| {
		Object.{ ns, id, .. } = obj
		r : { status : U16, web_socket : U32 }
		r = Io.run!(Io.tree(["object.fetch", ns, id], |t| ObjectErr(t)))?
		Ok(Response.{ status: r.status, headers: [], body: Empty, web_socket: Js.Ref.fake(r.web_socket) })
	}

	call! : Object, Rpc(arg, ret), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str)])
		where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	call! = |obj, m, arg| Io.run!(obj.call(m, arg))

	## The stub as text, for the output of the check.
	describe : Object -> Str
	describe = |obj| {
		Object.{ ns, jurisdiction, id, hint } = obj
		"${ns} ${jurisdiction} ${id} ${hint}"
	}

	## The object that runs: its id and its storage. SQL and KV storage are sync: `call!`, no wait.
	Self := { class : Str, id : Str }.{
		## Pure: the event carries the id.
		id : Object.Self -> Str
		id = |self| self.id

		sql! : Object.Self, Str, List(Sql) => Try(rows, [SqlErr(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
			where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		sql! = |self, sql, params| self.sql_with!(sql, params, { max_bytes: Body.default_max })

		sql_with! : Object.Self, Str, List(Sql), { max_bytes : U64 } => Try(rows, [SqlErr(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
			where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		sql_with! = |self, sql, params, opts| Io.run!(Io.typed(sql_ops("do.sql", self, sql, params).append(Io.max(opts.max_bytes)), |t| sql_err(t)))

		## `rowsRead` and `rowsWritten` of the cursor. An object cursor has no `changes` (`Sql.Info` is D1 only).
		sql_run! : Object.Self, Str, List(Sql) => Try(Object.SqlInfo, [SqlErr(Io.Thrown), Constraint(Str)])
		sql_run! = |self, sql, params| Io.run!(Io.tree(sql_ops("do.sql_run", self, sql, params), |t| Sql.throw(t, |o| SqlErr(o))))

		sql_rows! : Object.Self, Str, List(Sql) => Try(Sql.Rows, [SqlErr(Io.Thrown), Constraint(Str), TooLarge])
		sql_rows! = |self, sql, params| self.sql_rows_with!(sql, params, { max_bytes: Body.default_max })

		sql_rows_with! : Object.Self, Str, List(Sql), { max_bytes : U64 } => Try(Sql.Rows, [SqlErr(Io.Thrown), Constraint(Str), TooLarge])
		sql_rows_with! = |self, sql, params, opts| Io.run!(Io.tree(sql_ops("do.sql_rows", self, sql, params).append(Io.max(opts.max_bytes)), |t| sql_err(t)))

		## `ctx.acceptWebSocket` and a 101 response with the client end, in one `call!`.
		accept! : Object.Self, Request => Try({ socket : Object.Socket, response : Response }, [NotUpgrade])
		accept! = |self, req|
			if WebSocket.is_upgrade(req) {
				r : Try({ server : U32, client : U32 }, _)
				r = Io.run!(Io.typed(["do.accept", self.id], |_| BadData("")))
				ends = r ?? { server: 0, client: 0 }
				Ok({ socket: Object.Socket.{ ref: Js.Ref.fake(ends.server) }, response: Response.{ status: 101, headers: [], body: Empty, web_socket: Js.Ref.fake(ends.client) } })
			} else {
				Err(NotUpgrade)
			}

		## `ctx.getWebSockets()`. The ref table gives one id to one JS object, so `==` finds the sender.
		sockets! : Object.Self => List(Object.Socket)
		sockets! = |self| {
			refs : Try(List(U32), _)
			refs = Io.run!(Io.typed(["do.sockets", self.id], |_| BadData("")))
			(refs ?? []).map(|ref| Object.Socket.{ ref: Js.Ref.fake(ref) })
		}
	}

	## What a SQL cursor of a Durable Object gives. D1 also gives changes and last_row_id (`Sql.Info`).
	SqlInfo : { rows_read : U64, rows_written : U64 }

	## A socket that the object accepted (hibernation API). Its attachment is CBOR.
	Socket := { ref : Js.Ref }.{
		is_eq : _

		send! : Object.Socket, WebSocket.Message => Try({}, [Closed])
		send! = |s, m| {
			text = match m {
				Text(t) => t
				Bytes(b) => Str.inspect(b)
			}
			_ = Io.run!(Io.new(["ws.send", s.ref.to_str(), text], |r| r))
			Ok({})
		}

		send_json! : Object.Socket, a => Try({}, [Closed]) where [a.Json.Encodable([])]
		send_json! = |s, v| s.send!(Text(Json.to_str(v)))

		close! : Object.Socket, U16, Str => {}
		close! = |s, code, reason| {
			_ = Io.run!(Io.new(["ws.close", s.ref.to_str(), code.to_str(), reason], |r| r))
			{}
		}

		attach! : Object.Socket, a => Try({}, [TooLarge]) where [a.Cbor.Encodable([])]
		attach! = |s, v| {
			bytes = Cbor.encode(v)
			if bytes.len() > 16384 {
				Err(TooLarge)
			} else {
				_ = Io.run!(Io.new(["ws.attach", s.ref.to_str(), Str.inspect(bytes)], |r| r))
				Ok({})
			}
		}

		attachment! : Object.Socket => Try(a, [NotFound, BadData(Str)]) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		attachment! = |s| match Io.run!(Io.new(["ws.attachment", s.ref.to_str()], |r| r)) {
			Ok(bytes) if bytes == Io.null => Err(NotFound)
			Ok(bytes) => Io.decode(bytes)
			Err(_) => Err(NotFound)
		}
	}

	Class : { name : Str, run! : Object.Self, Object.Event => Object.Outcome }

	## API.md 10.1.
	Event : [
		Init,
		Fetch(Request),
		Alarm({ retry_count : U32, is_retry : Bool }),
		Rpc({ method : Str, arg : List(U8) }),
		SocketMessage(Object.Socket, WebSocket.Message),
		SocketClose(Object.Socket, WebSocket.Closed),
		SocketError(Object.Socket, Io.Thrown),
	]

	## `Reply`: the reply as `Packed` CBOR (API.md 5.2, 10.1).
	Outcome : [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled]

	## The class of an object: its handlers, all optional. Errors are logged, so each class can have its own.
	class : Str, {
		init! ?: Object.Self => Try({}, e),
		fetch! ?: Object.Self, Request => Try(Response, e),
		rpc ?: List(Rpc.Handler(Object.Self)),
		alarm! ?: Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, e),
		web_socket_message! ?: Object.Self, Object.Socket, WebSocket.Message => Try({}, e),
		web_socket_close! ?: Object.Self, Object.Socket, WebSocket.Closed => Try({}, e),
		web_socket_error! ?: Object.Self, Object.Socket, Io.Thrown => Try({}, e),
	} -> Object.Class
	class = |name, h| {
		name,
		run!: |self, ev| match ev {
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
			Rpc({ method, arg }) => match Rpc.serve!(h.?rpc ?? [], self, method, arg) {
				Ok(bytes) => Reply(Packed(bytes))
				Err(msg) => Failed(msg)
			}
			Alarm(info) => match h.?alarm! {
				Ok(f!) => done(f!(self, info))
				Err(MissingField) => Unhandled
			}
			SocketMessage(socket, msg) => match h.?web_socket_message! {
				Ok(f!) => done(f!(self, socket, msg))
				Err(MissingField) => Unhandled
			}
			SocketClose(socket, closed) => match h.?web_socket_close! {
				Ok(f!) => done(f!(self, socket, closed))
				Err(MissingField) => Unhandled
			}
			SocketError(socket, thrown) => match h.?web_socket_error! {
				Ok(f!) => done(f!(self, socket, thrown))
				Err(MissingField) => Unhandled
			}
		},
	}

	## A declaration of one key in the storage of an object. The storage keeps the CBOR bytes.
	cell : Str -> Object.Cell(a) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	cell = |key| { key, write: |v| Cbor.encode(v), read: |b| Cbor.parse(b).map_err(|e| Str.inspect(e)) }

	Cell(a) := { key : Str, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{
		get! : Object.Cell(a), Object.Self => Try(a, [NotFound, StorageErr(Io.Thrown), BadData(Str)])
		get! = |c, self| {
			read = c.read
			match Io.run!(Io.new(["do.get", self.id, c.key], |r| r)) {
				Ok(bytes) if bytes == Io.null => Err(NotFound)
				Ok(bytes) => read(bytes).map_err(|m| BadData(m))
				Err(t) => Err(StorageErr(t))
			}
		}

		set! : Object.Cell(a), Object.Self, a => Try({}, [StorageErr(Io.Thrown)])
		set! = |c, self, v| {
			write = c.write
			Io.run!(Io.new(["do.put", self.id, c.key, Str.inspect(write(v))], |r| r.map_ok(|_| {}).map_err(|t| StorageErr(t))))
		}
	}
}

stub : Object.Namespace, Str, Try(Object.Location, [MissingField]) -> Object
stub = |ns, id, hint| Object.{ ns: ns.binding, jurisdiction: ns.jurisdiction, id, hint: hint.map_ok(|l| Str.inspect(l)) ?? "" }

jurisdiction_text : Object.Jurisdiction -> Str
jurisdiction_text = |j| match j {
	Eu => "eu"
	Us => "us"
	Fedramp => "fedramp"
}

sql_ops : Str, Object.Self, Str, List(Sql) -> List(Str)
sql_ops = |op, self, sql, params| [op, self.id, sql].concat(params.map(|p| p.to_param()))

sql_err : Io.Thrown -> [SqlErr(Io.Thrown), Constraint(Str), TooLarge]
sql_err = |t| if Io.too_large(t) TooLarge else Sql.throw(t, |o| SqlErr(o))

done : Try({}, e) -> Object.Outcome
done = |r| match r {
	Ok({}) => Done
	Err(e) => Failed(Str.inspect(e))
}
