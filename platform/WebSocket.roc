## WebSockets (MODULES.md 12.2): the socket of a Worker (`accept!`) and of a client (`connect!`). A socket holds a ref,
## so it is good for one task (MC13). JS keeps the messages that come before a `receive!` in a queue of at most
## `max_queued_bytes` (the helpers `wsPair`, `wsAccept` and `wsReceive` of `js/helpers.js`). The sockets of a Durable Object (the hibernation API, 12.1)
## are `Object.Socket`: the same `send!`, `send_json!` and `close!`, and no `receive!` (an object gets events).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Io
import Js
import Request
import Response
import Remote
import http.Header

WebSocket :: { ref : Js.Ref, protocol : Str }.{

	## Two values are the same socket when they hold the same ref (API.md RS1).
	is_eq : _

	## The subprotocol of the socket: of a client, the `Sec-WebSocket-Protocol` header of the 101 response of the server;
	## of `accept_with!`, the one that it picked. "" when there is none.
	protocol : WebSocket -> Str
	protocol = |ws| ws.protocol

	## One frame. `json` parses a text frame as JSON, the format of most WebSocket clients.
	Message := [Text(Str), Bytes(List(U8))].{
		is_eq : _

		json : WebSocket.Message -> Try(a, [BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
		json = |msg| match msg {
			Text(s) => Json.parse(s).map_err(|e| BadData(Str.inspect(e)))
			Bytes(_) => Err(BadData("a bytes frame, not a text frame"))
		}
	}

	## The close of a socket: the code and the reason of the close frame, `clean` (`wasClean`), and who closed first
	## (`by`): `Transport` for the code 1006 (no close frame: the connection dropped, RFC 6455 7.1.5), `Us` when this
	## side called `close!` first (also the close of a full receive queue, 1008), else `Peer`. When `Us` closed, the code
	## and the reason are the ones of the reply of the peer (local workerd: the code, with an empty reason).
	Closed : { code : U16, reason : Str, clean : Bool, by : [Peer, Us, Transport] }

	## The default limit of the receive queue of a socket: 4 MiB (`max_queued_bytes`).
	default_max_queued_bytes : U64
	default_max_queued_bytes = 4_194_304

	## The subprotocols that the client asks for: the `Sec-WebSocket-Protocol` headers of the request, split at the
	## commas, in their order.
	protocols : Request -> List(Str)
	protocols = |req| req.headers()
		.keep_if(|h| h.name.with_ascii_lowercased() == "sec-websocket-protocol")
		.join_map(|h| h.value.split_on(",").map(|p| p.trim()))
		.keep_if(|p| !p.is_empty())

	## The subprotocol that a server picks: the first of `supported` (the order of the server) that the client asks for.
	## `NotFound` when there is none: the 101 response then has no `Sec-WebSocket-Protocol`, and a client that asked
	## for one fails the connection (RFC 6455 4.1).
	pick_protocol : Request, List(Str) -> Try(Str, [NotFound])
	pick_protocol = |req, supported| {
		asked = protocols(req)
		supported.find_first(|p| asked.contains(p))
	}

	## The request asks for a WebSocket: its `Upgrade` header is `websocket` (the case does not matter).
	is_upgrade : Request -> Bool
	is_upgrade = |req| match req.header("upgrade") {
		Ok(v) => v.trim().with_ascii_lowercased() == "websocket"
		Err(_) => Bool.False
	}

	## `new WebSocketPair()`, `accept()` of the server end, and a 101 response with the client end, in one `call!`.
	## Give `response.after(work!)` with a `receive!` loop in the work: a 101 response keeps the task until the socket
	## closes (API.md 10.2). `NotUpgrade` when the request has no `Upgrade: websocket`.
	accept! : Request => Try({ socket : WebSocket, response : Response }, [NotUpgrade])
	accept! = |req| accept_with!(req, {})

	## `protocols`: the subprotocols of the server, in its order. The socket gets the first that the client asks for
	## (`pick_protocol`), and the 101 response has it in `Sec-WebSocket-Protocol`. `max_queued_bytes`: the limit of the
	## receive queue (default `default_max_queued_bytes`). Workers has no backpressure on a WebSocket: a message that
	## comes while the queue holds that many bytes or more closes the socket with 1008 "receive queue full", and it and
	## the later messages are dropped. The messages in the queue stay for `receive!`, then `Closed` with `by: Us`.
	accept_with! : Request, { protocols ?: List(Str), max_queued_bytes ?: U64 } => Try({ socket : WebSocket, response : Response }, [NotUpgrade])
	accept_with! = |req, opts|
		if !is_upgrade(req) {
			Err(NotUpgrade)
		} else {
			max = opts.?max_queued_bytes ?? default_max_queued_bytes
			match Js.call!([Call(Root("pf"), "wsPair", [Lit(Int(max.to_i64_try() ?? I64.highest))])]) {
				Ok(Arr([Ref(client), Ref(server)])) => {
					response = Response.from_status(101).with_web_socket(client)
					match pick_protocol(req, opts.?protocols ?? []) {
						Ok(p) => Ok({ socket: WebSocket.{ ref: server, protocol: p }, response: response.with_header("Sec-WebSocket-Protocol", p) })
						Err(NotFound) => Ok({ socket: WebSocket.{ ref: server, protocol: "" }, response })
					}
				}
				Ok(other) => crash "WebSocket.accept_with!: pf.wsPair gave ${Str.inspect(other)}"
				Err(t) => crash "WebSocket.accept_with!: ${t.name}: ${t.message}"
			}
		}

	## A client: `fetch(url)` with `Upgrade: websocket`, then `accept()` of the `webSocket` of the response, in one
	## program with one wait. A `ws://` or `wss://` URL is sent as `http://` or `https://` (the `fetch` of Workers takes
	## only these). `NotUpgrade` when the server does not answer 101. A throw of `fetch` is `SocketErr`.
	connect : Str -> Io(WebSocket, [NotUpgrade, Infra([SocketErr(Io.Thrown)])])
	connect = |url| connect_with(url, {})

	connect! : Str => Try(WebSocket, [NotUpgrade, Infra([SocketErr(Io.Thrown)])])
	connect! = |url| Io.run!(connect(url))

	## `headers`: more request headers. `protocols`: the header `Sec-WebSocket-Protocol` (`ws.protocol()` gives the one
	## that the server picked). `max_queued_bytes`: the limit of the receive queue, as for `accept_with!`.
	connect_with : Str, { headers ?: List(Header), protocols ?: List(Str), max_queued_bytes ?: U64 } -> Io(WebSocket, [NotUpgrade, Infra([SocketErr(Io.Thrown)])])
	connect_with = |url, opts| {
		extra = (opts.?headers ?? []).map(|h| Arr([Text(h.name), Text(h.value)]))
		offer = match opts.?protocols {
			Ok(list) if !list.is_empty() => [Arr([Text("Sec-WebSocket-Protocol"), Text(Str.join_with(list, ", "))])]
			_ => []
		}
		headers = [Arr([Text("Upgrade"), Text("websocket")])].concat(extra).concat(offer)
		Io.new(
			[
				Call(Root("global"), "fetch", [Lit(Text(http_url(url))), Lit(Obj([("headers", Arr(headers))]))]),
				Get(Slot(0), "webSocket"),
				Call(Root("pf"), "wsAccept", [Slot(1), Slot(0), Lit(Int((opts.?max_queued_bytes ?? default_max_queued_bytes).to_i64_try() ?? I64.highest))]),
			],
			|r| match r {
				Ok(Arr([Ref(ws), Text(picked)])) => Ok(WebSocket.{ ref: ws, protocol: picked })
				Ok(_) => Err(NotUpgrade)
				Err(t) => Err(Infra(SocketErr(t)))
			},
		)
	}

	connect_with! : Str, { headers ?: List(Header), protocols ?: List(Str), max_queued_bytes ?: U64 } => Try(WebSocket, [NotUpgrade, Infra([SocketErr(Io.Thrown)])])
	connect_with! = |url, opts| Io.run!(connect_with(url, opts))

	## `ws.send(data)`, one `call!`. `Closed` when this side or the peer closed the socket (`readyState` 2 or 3). Another
	## throw of `send` is `SocketErr` (none is known locally: a send of 64 MiB works).
	send! : WebSocket, WebSocket.Message => Try({}, [Closed, Infra([SocketErr(Io.Thrown)])])
	send! = |ws, msg| Remote.socket_send!(ws.ref, frame(msg))

	## The value as JSON text, in a text frame. A value that JSON cannot show (a `NaN` in an `F64`) is `BadData`, and
	## nothing is sent.
	send_json! : WebSocket, a => Try({}, [Closed, Infra([BadData(Str), SocketErr(Io.Thrown)])]) where [a.Json.Encodable(enc)]
	send_json! = |ws, value| match Json.to_str_try(value) {
		Ok(text) => match Remote.socket_send!(ws.ref, Text(text)) {
			Ok({}) => Ok({})
			Err(Closed) => Err(Closed)
			Err(Infra(SocketErr(t))) => Err(Infra(SocketErr(t)))
		}
		Err(e) => Err(Infra(BadData(Str.inspect(e))))
	}

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

	## `ws.close(code, reason)`, one `call!`. `BadCode`: a code that the app cannot send (1000 to 4999 only, not 1004
	## to 1006 or 1015: Workers checks it). `TooLarge`: a reason of more than 123 bytes (UTF-8). A close of a socket that
	## is closed already is `Ok`.
	close! : WebSocket, U16, Str => Try({}, [BadCode, TooLarge])
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

## The close record of `pf.wsReceive` and of the event `socketClose`: `{ code, reason, clean, by }`.
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
	by = match get("by") {
		Text("us") => Us
		Text("transport") => Transport
		Text("peer") => Peer
		other => crash "WebSocket: the close record has by ${Str.inspect(other)}"
	}
	{ code, reason, clean: get("clean") == Bool(Bool.True), by }
}

expect http_url("ws://a.dev/x") == "http://a.dev/x"
expect http_url("wss://a.dev/x") == "https://a.dev/x"
expect http_url("https://a.dev/x") == "https://a.dev/x"
expect closed_of([("code", Int(1000)), ("reason", Text("bye")), ("clean", Bool(Bool.True)), ("by", Text("peer"))]) == { code: 1000, reason: "bye", clean: Bool.True, by: Peer }
expect closed_of([("code", Int(4002)), ("reason", Text("")), ("clean", Bool(Bool.True)), ("by", Text("us"))]).by == Us
expect closed_of([("code", Int(1006)), ("reason", Text("x")), ("clean", Bool(Bool.False)), ("by", Text("transport"))]).by == Transport
expect WebSocket.protocols(Request.get("http://x/").with_header("Sec-WebSocket-Protocol", "chat, v2").with_header("sec-websocket-protocol", "v3")) == ["chat", "v2", "v3"]
expect WebSocket.protocols(Request.get("http://x/")) == []
expect WebSocket.pick_protocol(Request.get("http://x/").with_header("Sec-WebSocket-Protocol", "chat, v2"), ["v2", "chat"]) == Ok("v2")
expect WebSocket.pick_protocol(Request.get("http://x/").with_header("Sec-WebSocket-Protocol", "chat"), ["v2"]) == Err(NotFound)
expect WebSocket.is_upgrade(Request.get("http://x/").with_header("Upgrade", "WebSocket"))
expect !WebSocket.is_upgrade(Request.get("http://x/"))
