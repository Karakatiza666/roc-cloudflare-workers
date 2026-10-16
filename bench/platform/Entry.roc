## The event as a `Js` value to `Worker.Event`, and `Worker.Outcome` to a `Js` value (API.md 4, `roc_event`).
## Not in `exposes`: only `main.roc` uses it. The shim (`js/events.js`) writes and reads the same shapes:
##
## | Value | Shape |
## | --- | --- |
## | Fetch | `{ kind: "fetch", request: { method, url, headers: [[name, value], ...], body, cf } }` |
## | Scheduled | `{ kind: "scheduled", cron, time_ms }` |
## | Queue | `{ kind: "queue", queue, messages: [{ id, timestamp_ms, attempts, body }] }`, `body` as `Packed` (CBOR), or undefined for a body that CBOR cannot write |
## | Email | `{ kind: "email", from, to, headers: [[name, value], ...], raw, raw_size_bytes, can_be_forwarded }`, `raw` a stream (a ref) |
## | Tail | `{ kind: "tail", items }`, `items` as `Packed`: the items of `Worker.TraceItem` in the tag form of `Try` |
## | Other | `{ kind: "other", name, payload }` |
## | Rpc | `{ kind: "rpc", entrypoint, method, arg }`: `entrypoint` is "default" for the default export, `arg` is `Packed` |
## | EntrypointFetch | `{ kind: "entrypointFetch", entrypoint, request }` |
## | Object | `{ kind: "object", class, id, event }`, `event`: `{ kind: "init" }`, `{ kind: "fetch", request }`, `{ kind: "alarm", retry_count, is_retry }`, `{ kind: "rpc", method, arg }` |
## | Manifest | `{ kind: "manifest" }` |
## | body | `undefined` (Empty), bytes, text, or a ref (a stream) |
## | cf | `undefined`, or an object with each field of `Request.Cf` as `{ Ok: v }` or `{ Err: "Missing" }` |
## | Outcome | `{ outcome: "respond", status, headers, body, webSocket? }`, `{ outcome: "reply", value }`, `{ outcome: "done" }`, `{ outcome: "failed", message }`, `{ outcome: "unhandled" }` |
import Js
import Body
import Request
import Response
import Worker
import Queue
import Email
import Object
import cbor.Cbor
import http.Header
import http.Method

Entry :: [].{

	## A shape that is not in the table is a platform bug: a crash, with the text in the log.
	event : Js -> Worker.Event
	event = |js| {
		fields = obj(js, "event")
		match get(fields, "kind") {
			Text("fetch") => Fetch(request(get(fields, "request")))
			Text("scheduled") => Scheduled(Worker.Scheduled.{ cron: text(get(fields, "cron"), "cron"), time_ms: u64(get(fields, "time_ms"), "time_ms") })
			Text("queue") => Queue(queue_batch(fields))
			Text("email") => Email(mail(fields))
			Text("tail") => Tail(trace_items(fields))
			Text("other") => Other({ kind: text(get(fields, "name"), "name"), payload: get(fields, "payload") })
			Text("rpc") => Rpc({ entrypoint: text(get(fields, "entrypoint"), "entrypoint"), method: text(get(fields, "method"), "method"), arg: packed(get(fields, "arg"), "arg") })
			Text("entrypointFetch") => EntrypointFetch({ entrypoint: text(get(fields, "entrypoint"), "entrypoint"), request: request(get(fields, "request")) })
			Text("object") => Object({ class: text(get(fields, "class"), "class"), id: text(get(fields, "id"), "id"), event: object_event(get(fields, "event")) })
			Text("manifest") => Manifest
			other => crash "Entry.event: unknown kind ${Str.inspect(other)}"
		}
	}

	outcome : Worker.Outcome -> Js
	outcome = |o| match o {
		Respond(res) => {
			base = [
				("outcome", Text("respond")),
				("status", Int(res.status.to_i64())),
				("headers", Arr(res.headers.map(|h| Arr([Text(h.name), Text(h.value)])))),
				("body", body_js(res.body)),
			]
			match res.?web_socket {
				Ok(r) => Obj(base.append(("webSocket", Ref(r))))
				Err(_) => Obj(base)
			}
		}
		Reply(v) => Obj([("outcome", Text("reply")), ("value", v)])
		Done => Obj([("outcome", Text("done"))])
		Failed(msg) => Obj([("outcome", Text("failed")), ("message", Text(msg))])
		Unhandled => Obj([("outcome", Text("unhandled"))])
	}
}

## The event of an object (API.md 10.1). The socket events come with `WebSocket`.
object_event : Js -> Object.Event
object_event = |js| {
	f = obj(js, "object event")
	match get(f, "kind") {
		Text("init") => Init
		Text("fetch") => Fetch(request(get(f, "request")))
		Text("alarm") => Alarm({ retry_count: u32(get(f, "retry_count"), "retry_count"), is_retry: get(f, "is_retry") == Bool(Bool.True) })
		Text("rpc") => Rpc({ method: text(get(f, "method"), "method"), arg: packed(get(f, "arg"), "arg") })
		other => crash "Entry: unknown object event ${Str.inspect(other)}"
	}
}

## Typed data as one `Packed` value (API.md 5.2): its CBOR bytes.
packed : Js, Str -> List(U8)
packed = |js, what| match js {
	Packed(bytes) => bytes
	other => crash "Entry: ${what} is ${Str.inspect(other)}"
}

request : Js -> Request
request = |js| {
	f = obj(js, "request")
	method = method_of(text(get(f, "method"), "method"))
	url = text(get(f, "url"), "url")
	headers = match get(f, "headers") {
		Arr(items) => items.map(header_of)
		other => crash "Entry: headers is ${Str.inspect(other)}"
	}
	body = body_of(get(f, "body"))
	match get(f, "cf") {
		Undefined => Request.{ method, url, headers, body }
		cf => Request.{ method, url, headers, body, cf: cf_of(cf) }
	}
}

## A queue batch. A message with no body (JS could not write it as CBOR) has an empty one: `each!` retries it.
queue_batch : List((Str, Js)) -> Queue.Batch
queue_batch = |f| {
	messages = match get(f, "messages") {
		Arr(items) => items.map(queue_message)
		other => crash "Entry: messages is ${Str.inspect(other)}"
	}
	Queue.Batch.{ queue: text(get(f, "queue"), "queue"), messages }
}

queue_message : Js -> Queue.Message
queue_message = |js| {
	m = obj(js, "message")
	body = match get(m, "body") {
		Packed(bytes) => bytes
		_ => []
	}
	Queue.Message.{
		id: text(get(m, "id"), "id"),
		timestamp_ms: u64(get(m, "timestamp_ms"), "timestamp_ms"),
		attempts: u32(get(m, "attempts"), "attempts"),
		body,
	}
}

mail : List((Str, Js)) -> Email.Mail
mail = |f| Email.Mail.{
	from: text(get(f, "from"), "from"),
	to: text(get(f, "to"), "to"),
	headers: match get(f, "headers") {
		Arr(items) => items.map(header_of)
		other => crash "Entry: headers is ${Str.inspect(other)}"
	},
	raw: body_of(get(f, "raw")),
	raw_size_bytes: u64(get(f, "raw_size_bytes"), "raw_size_bytes"),
	can_be_forwarded: get(f, "can_be_forwarded") == Bool(Bool.True),
}

## The batch of a Tail Worker: one `Packed` value, parsed into the typed items (MODULES.md 3). A shape that does not
## fit is a platform bug: a crash, with the text of the parse error.
trace_items : List((Str, Js)) -> List(Worker.TraceItem)
trace_items = |f| match get(f, "items") {
	Packed(bytes) => {
		items : Try(List(Worker.TraceItem), _)
		items = Cbor.parse(bytes)
		match items {
			Ok(list) => list
			Err(e) => crash "Entry.event: the tail items do not fit Worker.TraceItem: ${Str.inspect(e)}"
		}
	}
	other => crash "Entry: items is ${Str.inspect(other)}"
}

method_of : Str -> Method
method_of = |s| match s {
	"GET" => GET
	"POST" => POST
	"PUT" => PUT
	"DELETE" => DELETE
	"HEAD" => HEAD
	"OPTIONS" => OPTIONS
	"PATCH" => PATCH
	"TRACE" => TRACE
	"CONNECT" => CONNECT
	"QUERY" => QUERY
	_ => Unknown(s)
}

header_of : Js -> Header
header_of = |js| match js {
	Arr([Text(name), Text(value)]) => Header.{ name, value }
	other => crash "Entry: a header is ${Str.inspect(other)}"
}

body_of : Js -> Body
body_of = |js| match js {
	Undefined | Null => Empty
	Bytes(b) => Bytes(b)
	Text(s) => Text(s)
	Ref(r) => Stream(r)
	other => crash "Entry: a body is ${Str.inspect(other)}"
}

body_js : Body -> Js
body_js = |b| match b {
	Empty => Null
	Text(s) => Text(s)
	Bytes(bytes) => Bytes(bytes)
	Stream(r) => Ref(r)
}

cf_of : Js -> Request.Cf
cf_of = |js| {
	f = obj(js, "cf")
	{
		asn: tried(f, "asn").map_ok(|v| u32(v, "asn")),
		as_organization: tried_text(f, "as_organization"),
		colo: tried_text(f, "colo"),
		country: tried_text(f, "country"),
		is_eu_country: get(f, "is_eu_country") == Bool(Bool.True),
		city: tried_text(f, "city"),
		continent: tried_text(f, "continent"),
		region: tried_text(f, "region"),
		region_code: tried_text(f, "region_code"),
		postal_code: tried_text(f, "postal_code"),
		metro_code: tried_text(f, "metro_code"),
		latitude: tried_text(f, "latitude"),
		longitude: tried_text(f, "longitude"),
		timezone: tried_text(f, "timezone"),
		http_protocol: tried_text(f, "http_protocol"),
		tls_version: tried_text(f, "tls_version"),
		tls_cipher: tried_text(f, "tls_cipher"),
		client_tcp_rtt_ms: tried(f, "client_tcp_rtt_ms").map_ok(|v| u64(v, "client_tcp_rtt_ms")),
	}
}

## A field in the tag form of the shim: `{ Ok: v }` or `{ Err: "Missing" }` (MODULES.md 4, never null).
tried : List((Str, Js)), Str -> Try(Js, [Missing])
tried = |fields, name| match get(fields, name) {
	Obj([("Ok", v)]) => Ok(v)
	Obj([("Err", Text("Missing"))]) => Err(Missing)
	other => crash "Entry: cf.${name} is ${Str.inspect(other)}"
}

tried_text : List((Str, Js)), Str -> Try(Str, [Missing])
tried_text = |fields, name| tried(fields, name).map_ok(|v| text(v, name))

obj : Js, Str -> List((Str, Js))
obj = |js, what| match js {
	Obj(fields) => fields
	other => crash "Entry: ${what} is ${Str.inspect(other)}"
}

## The value of a key, or `Undefined`.
get : List((Str, Js)), Str -> Js
get = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

text : Js, Str -> Str
text = |js, what| match js {
	Text(s) => s
	other => crash "Entry: ${what} is ${Str.inspect(other)}"
}

u64 : Js, Str -> U64
u64 = |js, what| match js {
	Int(i) => i.to_u64_try() ?? crash "Entry: ${what} is negative"
	other => crash "Entry: ${what} is ${Str.inspect(other)}"
}

u32 : Js, Str -> U32
u32 = |js, what| match js {
	Int(i) => i.to_u32_try() ?? crash "Entry: ${what} is out of range"
	other => crash "Entry: ${what} is ${Str.inspect(other)}"
}
