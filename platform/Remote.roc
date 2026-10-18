## The programs that `Object`, `Service`, `Assets` and `WebSocket` share (MODULES.md 7, 8, 12, 13): a `fetch` on a stub or a
## binding, an RPC call with the argument and the reply as CBOR (MC5), and `send` and `close` of a socket. Not in `exposes`: only platform modules use it.
import Io
import Js
import Request
import Response
import Rpc
import http.Header
import cbor.Cbor

Remote :: [].{

	## `target.fetch(url, init)`: `ops` put the stub or the binding in the slot `target`. The response keeps its body a
	## stream, and a 101 response its `webSocket` (a ref), so a Worker can give it to the client.
	fetch : List(Js.Op), U32, Request, (Io.Thrown -> e) -> Io(Response, e)
	fetch = |ops, target, req, err| {
		n = ops.len().to_u32_wrap()
		Io.new(
			ops.concat([Record(init(req)), Call(Slot(target), "fetch", [Lit(Text(req.url())), Slot(n)]), Fields(Slot(n + 1), ["status", "headers", "body", "webSocket"])]),
			|r| match r {
				Ok(v) => Ok(response_of(v))
				Err(t) => Err(err(t))
			},
		)
	}

	## `target[name](arg)`: the argument as one `Packed` value, which JS gives the callee as a plain JS value, and the
	## reply as one `Packed` value of at most `max` bytes (`pf.pack`). The reply is `{"Ok": value}` or `{"Err": tag}`: its `Err` is
	## `Remote(err)`. A reply that does not fit is `BadData`. A throw of the callee, of Workers (no method, the size limit
	## of RPC) or of `pf.pack` (`TooLarge`) is `RpcErr`.
	call : List(Js.Op), U32, Rpc(arg, ret, err), arg, U64 -> Io(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err)]) where [arg.Cbor.Encodable([]), ret.Cbor.Parseable([InvalidCbor(U64), ..e1]), err.Cbor.Parseable([InvalidCbor(U64), ..e2])]
	call = |ops, target, m, a, max| {
		n = ops.len().to_u32_wrap()
		Io.new(
			ops.concat([Call(Slot(target), m.name(), [Lit(Packed(Cbor.encode(a)))]), Call(Root("pf"), "pack", [Slot(n), Lit(Int(max.to_i64_try() ?? I64.highest))])]),
			|r| match r {
				Ok(Packed(bytes)) => Rpc.reply_of(bytes)
				Ok(other) => crash "Rpc: pf.pack gave ${Str.inspect(other)}"
				Err(t) => Err(RpcErr(t))
			},
		)
	}

	## `ws.send(data)` on a socket of `WebSocket` or `Object.Socket` (MODULES.md 12, "One API"), one `call!`. A throw (the
	## socket is closed) is `Closed`.
	socket_send! : Js.Ref, Js => Try({}, [Closed])
	socket_send! = |ref, data| match Js.call!([Call(Ref(ref), "send", [Lit(data)])]) {
		Ok(_) => Ok({})
		Err(_) => Err(Closed)
	}

	## `ws.close(code, reason)`, one `call!`. A throw (a code that the app cannot send, a closed socket) is dropped.
	socket_close! : Js.Ref, U16, Str => {}
	socket_close! = |ref, code, reason| {
		_ = Js.call!([Call(Ref(ref), "close", [Lit(Int(code.to_i64())), Lit(Text(reason))])])
		{}
	}

	## The limit of one RPC call of Workers (32 MiB, Cloudflare docs): the limit of a reply that crosses into wasm.
	rpc_max : U64
	rpc_max = 33_554_432
}

## The `RequestInit` of a request: the method, the headers and the body (a stream body is its ref, with no copy).
init : Request -> List((Str, Js.Arg))
init = |req| {
	base = [
		("method", Lit(Text(req.method().to_str()))),
		("headers", Lit(Arr(req.headers().map(|h| Arr([Text(h.name), Text(h.value)]))))),
	]
	match req.body() {
		Empty => base
		Text(s) => base.append(("body", Lit(Text(s))))
		Bytes(b) => base.append(("body", Lit(Bytes(b))))
		Stream(r) => base.append(("body", Lit(Ref(r))))
	}
}

## The `Fields` of a response as a `Response`. A shape that is not that record is a platform bug: a crash.
response_of : Js -> Response
response_of = |v| match v {
	Obj(fields) => {
		status = match field(fields, "status") {
			Int(i) => i.to_u16_try() ?? crash "Remote: the status ${i.to_str()} is out of range"
			other => crash "Remote: the status is ${Str.inspect(other)}"
		}
		headers = match field(fields, "headers") {
			Arr(items) => items.map(
				|h| match h {
					Arr([Text(name), Text(value)]) => Header.{ name, value }
					other => crash "Remote: a header is ${Str.inspect(other)}"
				},
			)
			other => crash "Remote: the headers are ${Str.inspect(other)}"
		}
		body = match field(fields, "body") {
			Undefined | Null => Empty
			Ref(r) => Stream(r)
			other => crash "Remote: the body is ${Str.inspect(other)}"
		}
		match field(fields, "webSocket") {
			Ref(ws) => Response.from_status(status).with_headers(headers).with_body(body).with_web_socket(ws)
			_ => Response.from_status(status).with_headers(headers).with_body(body)
		}
	}
	other => crash "Remote: the response is ${Str.inspect(other)}"
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

expect init(Request.get("https://x.dev/a.txt")).len() == 2
# A body goes into the init as it is (text, bytes or a stream).
expect init(Request.post("https://x.dev/a", Text("abc"))).len() == 3
expect response_of(Obj([("status", Int(404)), ("headers", Arr([])), ("body", Null)])).status() == 404
