## WebSockets (MODULES.md 12.2): the socket of a Worker (`accept!`) and of a client (`connect!`). A socket holds a ref,
## so it is good for one task (MC13). JS keeps the messages that come before a `receive!` in a queue (the helpers
## `wsPair`, `wsAccept` and `wsReceive` of `js/helpers.js`). The sockets of a Durable Object (the hibernation API, 12.1)
## are `Object.Socket`: the same `send!`, `send_json!` and `close!`, and no `receive!` (an object gets events).
import Io
import Js
import Request
import Response
import Remote
import http.Header

WebSocket :: { ref : Js.Ref }.{
	## Two values are the same socket when they hold the same ref (API.md RS1).
	is_eq : _

	## One frame. `json` parses a text frame as JSON, the format of most WebSocket clients.
	Message := [Text(Str), Bytes(List(U8))].{
		is_eq : _

		json : WebSocket.Message -> Try(a, [BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
		json = |msg| match msg {
			Text(s) => Json.parse(s).map_err(|e| BadData(Str.inspect(e)))
			Bytes(_) => Err(BadData("a bytes frame, not a text frame"))
		}
	}

	## The close of a socket: the code and the reason of the close frame, and `clean` (`wasClean`).
	Closed : { code : U16, reason : Str, clean : Bool }

	## The request asks for a WebSocket: its `Upgrade` header is `websocket` (the case does not matter).
	is_upgrade : Request -> Bool
	is_upgrade = |req| match req.header("upgrade") {
		Ok(v) => v.trim().with_ascii_lowercased() == "websocket"
		Err(_) => Bool.False
	}

	## `new WebSocketPair()`, `accept()` of the server end, and a 101 response with the client end, in one `call!`.
	## Give the response to `Ctx.respond!`, then `receive!` in a loop: a 101 response keeps the task until the socket
	## closes (API.md 10.2). `NotUpgrade` when the request has no `Upgrade: websocket`.
	accept! : Request => Try({ socket : WebSocket, response : Response }, [NotUpgrade])
	accept! = |req|
		if !is_upgrade(req) {
			Err(NotUpgrade)
		} else {
			match Io.call!([Call(Root("pf"), "wsPair", [])]) {
				Ok(Arr([Ref(client), Ref(server)])) => Ok({ socket: WebSocket.{ ref: server }, response: Response.{ status: 101, web_socket: client } })
				Ok(other) => crash "WebSocket.accept!: pf.wsPair gave ${Str.inspect(other)}"
				Err(t) => crash "WebSocket.accept!: ${t.name}: ${t.message}"
			}
		}

	## A client: `fetch(url)` with `Upgrade: websocket`, then `accept()` of the `webSocket` of the response, in one
	## program with one wait. A `ws://` or `wss://` URL is sent as `http://` or `https://` (the `fetch` of Workers takes
	## only these). `NotUpgrade` when the server does not answer 101. A throw of `fetch` is `SocketErr`.
	connect : Str -> Io(WebSocket, [NotUpgrade, SocketErr(Io.Thrown)])
	connect = |url| connect_with(url, {})

	connect! : Str => Try(WebSocket, [NotUpgrade, SocketErr(Io.Thrown)])
	connect! = |url| Io.run!(connect(url))

	## `headers`: more request headers. `protocols`: the header `Sec-WebSocket-Protocol`.
	connect_with : Str, { headers ?: List(Header), protocols ?: List(Str) } -> Io(WebSocket, [NotUpgrade, SocketErr(Io.Thrown)])
	connect_with = |url, opts| {
		extra = (opts.?headers ?? []).map(|h| Arr([Text(h.name), Text(h.value)]))
		protocols = match opts.?protocols {
			Ok(list) if !list.is_empty() => [Arr([Text("Sec-WebSocket-Protocol"), Text(Str.join_with(list, ", "))])]
			_ => []
		}
		headers = [Arr([Text("Upgrade"), Text("websocket")])].concat(extra).concat(protocols)
		Io.new(
			[
				Call(Root("global"), "fetch", [Lit(Text(http_url(url))), Lit(Obj([("headers", Arr(headers))]))]),
				Get(Slot(0), "webSocket"),
				Call(Root("pf"), "wsAccept", [Slot(1)]),
			],
			|r| match r {
				Ok(Ref(ws)) => Ok(WebSocket.{ ref: ws })
				Ok(_) => Err(NotUpgrade)
				Err(t) => Err(SocketErr(t))
			},
		)
	}

	connect_with! : Str, { headers ?: List(Header), protocols ?: List(Str) } => Try(WebSocket, [NotUpgrade, SocketErr(Io.Thrown)])
	connect_with! = |url, opts| Io.run!(connect_with(url, opts))

	## `ws.send(data)`, one `call!`. A throw (the socket is closed) is `Closed`.
	send! : WebSocket, WebSocket.Message => Try({}, [Closed])
	send! = |ws, msg| Remote.socket_send!(ws.ref, frame(msg))

	## The value as JSON text, in a text frame.
	send_json! : WebSocket, a => Try({}, [Closed]) where [a.Json.Encodable([])]
	send_json! = |ws, value| Remote.socket_send!(ws.ref, Text(Json.to_str(value)))

	## The next message: one wait (`pf.wsReceive`), with no deadline (API.md 10.2). After the close, each call gives
	## `Closed`. In `Io.race!`, a branch that lost takes no message: it stays for the next call (OP8).
	receive : WebSocket -> Io(WebSocket.Message, [Closed(WebSocket.Closed)])
	receive = |ws| Io.new(
		[Keep(Root("signal")), Call(Root("pf"), "wsReceive", [Lit(Ref(ws.ref)), Slot(0)])],
		|r| match r {
			Ok(Text(s)) => Ok(Text(s))
			Ok(Bytes(b)) => Ok(Bytes(b))
			Ok(Obj(fields)) => Err(Closed(closed_of(fields)))
			Ok(other) => crash "WebSocket.receive: pf.wsReceive gave ${Str.inspect(other)}"
			Err(t) => crash "WebSocket.receive: ${t.name}: ${t.message}"
		},
	)

	receive! : WebSocket => Try(WebSocket.Message, [Closed(WebSocket.Closed)])
	receive! = |ws| Io.run!(receive(ws))

	## `ws.close(code, reason)`, one `call!`. A throw (a code that the app cannot send, a closed socket) is dropped.
	close! : WebSocket, U16, Str => {}
	close! = |ws, code, reason| Remote.socket_close!(ws.ref, code, reason)
}

## A frame as the value of `ws.send(data)`.
frame : WebSocket.Message -> Js
frame = |msg| match msg {
	Text(s) => Text(s)
	Bytes(b) => Bytes(b)
}

## `ws://` and `wss://` as `http://` and `https://`: the `fetch` of Workers refuses the WebSocket schemes
## (`research/sockets-probe/out.txt`: "Fetch API cannot load: ws://...").
http_url : Str -> Str
http_url = |url|
	if url.starts_with("ws://") {
		"http://${url.drop_prefix("ws://")}"
	} else if url.starts_with("wss://") {
		"https://${url.drop_prefix("wss://")}"
	} else {
		url
	}

## The close record of `pf.wsReceive`: `{ code, reason, clean }`.
closed_of : List((Str, Js)) -> WebSocket.Closed
closed_of = |fields| {
	get = |name| match fields.find_first(|(k, _)| k == name) {
		Ok((_, v)) => v
		Err(_) => Undefined
	}
	code = match get("code") {
		Int(i) => i.to_u16_try() ?? 1006
		_ => 1006
	}
	reason = match get("reason") {
		Text(s) => s
		_ => ""
	}
	{ code, reason, clean: get("clean") == Bool(Bool.True) }
}

expect http_url("ws://a.dev/x") == "http://a.dev/x"
expect http_url("wss://a.dev/x") == "https://a.dev/x"
expect http_url("https://a.dev/x") == "https://a.dev/x"
expect closed_of([("code", Int(1000)), ("reason", Text("bye")), ("clean", Bool(Bool.True))]) == { code: 1000, reason: "bye", clean: Bool.True }
expect WebSocket.is_upgrade(Request.get("http://x/").with_header("Upgrade", "WebSocket"))
expect !WebSocket.is_upgrade(Request.get("http://x/"))
