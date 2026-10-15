import Io
import Cbor
import Rpc
import Sql
import Request
import Response
import WebSocket

## A Durable Object stub: plain data, like a binding (API.md 6.3).
Object :: { ns : Str, id : Str }.{
	namespace : Str -> Object.Namespace
	namespace = |binding| { binding, }

	Namespace := { binding : Str }.{
		## `idFromName` is a pure function of the name, so this needs no crossing.
		named : Object.Namespace, Str -> Object
		named = |ns, name| Object.{ ns: ns.binding, id: "name:${name}" }
	}

	call : Object, Rpc(arg, ret), arg -> Io(ret, [RpcErr(Io.Thrown), BadData(Str)])
		where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	call = |obj, m, arg| {
		Object.{ ns, id } = obj
		m.call(["object", ns, id], arg)
	}

	## `stub.fetch(request)`. A 101 response keeps its `web_socket`, so a Worker can give it to the client.
	fetch! : Object, Request => Try(Response, [ObjectErr(Io.Thrown), BadData(Str)])
	fetch! = |obj, _req| {
		Object.{ ns, id } = obj
		r : { status : U16, web_socket : U32 }
		r = Io.run!(Io.typed(["object.fetch", ns, id], |t| ObjectErr(t)))?
		Ok(Response.{ status: r.status, headers: [], body: Empty, web_socket: r.web_socket })
	}

	call! : Object, Rpc(arg, ret), arg => Try(ret, [RpcErr(Io.Thrown), BadData(Str)])
		where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	call! = |obj, m, arg| Io.run!(obj.call(m, arg))

	## The object that runs: its id and its storage. SQL and KV storage are sync: `call!`, no wait.
	Self := { class : Str, id : Str }.{
		sql! : Object.Self, Str, List(Sql) => Try(rows, [SqlErr(Io.Thrown), BadData(Str)])
			where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		sql! = |self, sql, params| Io.run!(Io.typed(["do.sql", self.id, sql].concat(params.map(|p| p.to_param())), |t| SqlErr(t)))

		## `ctx.acceptWebSocket` and a 101 response with the client end, in one `call!`.
		accept! : Object.Self, Request => Try({ socket : Object.Socket, response : Response }, [NotUpgrade])
		accept! = |self, req|
			if WebSocket.is_upgrade(req) {
				r : Try({ server : U32, client : U32 }, _)
				r = Io.run!(Io.typed(["do.accept", self.id], |_| BadData("")))
				ends = r ?? { server: 0, client: 0 }
				Ok({ socket: Object.Socket.{ ref: ends.server }, response: Response.{ status: 101, headers: [], body: Empty, web_socket: ends.client } })
			} else {
				Err(NotUpgrade)
			}

		## `ctx.getWebSockets()`. The ref table gives one id to one JS object, so `==` finds the sender.
		sockets! : Object.Self => List(Object.Socket)
		sockets! = |self| {
			refs : Try(List(U32), _)
			refs = Io.run!(Io.typed(["do.sockets", self.id], |_| BadData("")))
			(refs ?? []).map(|ref| Object.Socket.{ ref })
		}
	}

	## A socket that the object accepted (hibernation API). Its attachment is CBOR.
	Socket := { ref : U32 }.{
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

	Event : [Fetch(Request), Rpc(Str, List(U8)), Alarm, SocketMessage(Object.Socket, WebSocket.Message), SocketClose(Object.Socket, WebSocket.Closed)]

	Outcome : [Respond(Response), Reply(List(U8)), Done, Failed(Str), Unhandled]

	## The class of an object: its handlers, all optional. Errors are logged, so each class can have its own.
	class : Str, { fetch! ?: Object.Self, Request => Try(Response, e), rpc ?: List(Rpc.Handler(Object.Self)), alarm! ?: Object.Self => Try({}, e), web_socket_message! ?: Object.Self, Object.Socket, WebSocket.Message => Try({}, e), web_socket_close! ?: Object.Self, Object.Socket, WebSocket.Closed => Try({}, e) } -> Object.Class
	class = |name, h| {
		name,
		run!: |self, ev| match ev {
			Fetch(req) => match h.?fetch! {
				Ok(f!) => match f!(self, req) {
					Ok(res) => Respond(res)
					Err(e) => Failed(Str.inspect(e))
				}
				Err(MissingField) => Unhandled
			}
			Rpc(method, arg) => match Rpc.serve!(h.?rpc ?? [], self, method, arg) {
				Ok(bytes) => Reply(bytes)
				Err(msg) => Failed(msg)
			}
			Alarm => match h.?alarm! {
				Ok(f!) => match f!(self) {
					Ok({}) => Done
					Err(e) => Failed(Str.inspect(e))
				}
				Err(MissingField) => Unhandled
			}
			SocketMessage(socket, msg) => match h.?web_socket_message! {
				Ok(f!) => match f!(self, socket, msg) {
					Ok({}) => Done
					Err(e) => Failed(Str.inspect(e))
				}
				Err(MissingField) => Unhandled
			}
			SocketClose(socket, closed) => match h.?web_socket_close! {
				Ok(f!) => match f!(self, socket, closed) {
					Ok({}) => Done
					Err(e) => Failed(Str.inspect(e))
				}
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
