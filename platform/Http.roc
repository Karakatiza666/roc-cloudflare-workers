## Outgoing HTTP (MODULES.md 4): `fetch`. `send!` reads the body in the same crossing, to a limit (MC11), so a read
## of the response after it needs no wait. `open!` keeps the body a stream in JS. Each status is `Ok`: only a throw of
## `fetch` is an `Err` (MC9, "Named error tags"): a `TypeError` is a bad request (`HttpErr`), each other throw is
## no response (`Network`).
import Io
import Js
import Body
import Request
import Response
import http.Header
import http.Method

Http :: [].{

	## `fetch(request)`, and the body to `Body.default_max` bytes: one wait.
	send : Request -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send = |req| Io.new(ops(req, Read(Body.default_max), Err(MissingField), Err(MissingField)), read)

	send! : Request => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send! = |req| Io.run!(send(req))

	## `max_bytes`: the limit of the body (default `Body.default_max`). `timeout_ms`: `AbortSignal.timeout`, a timeout
	## is `Network`. `cf`: the `cf` options of `fetch` (`cacheTtl`, `cacheEverything`), a `Js` object of the app.
	send_with : Request, { max_bytes ?: U64, timeout_ms ?: U64, cf ?: Js } -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send_with = |req, opts| Io.new(ops(req, Read(opts.?max_bytes ?? Body.default_max), opts.?timeout_ms, opts.?cf), read)

	send_with! : Request, { max_bytes ?: U64, timeout_ms ?: U64, cf ?: Js } => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	send_with! = |req, opts| Io.run!(send_with(req, opts))

	## `fetch(request)`: the body stays a stream in JS (a `Stream` body, MC13), for a large body or a pass-through.
	open : Request -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown)])
	open = |req| Io.new(
		ops(req, Keep, Err(MissingField), Err(MissingField)),
		|r| match r {
			Ok(v) => Ok(response_of(v))
			Err(t) => match Http.error(t) {
				Network(n) => Err(Network(n))
				HttpErr(h) => Err(HttpErr(h))
				_ => Err(Network(t))
			}
		},
	)

	open! : Request => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown)])
	open! = |req| Io.run!(open(req))

	## `send` of a `GET` of the URL.
	get : Str -> Io(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	get = |url| send(Request.get(url))

	get! : Str => Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
	get! = |url| Io.run!(get(url))

	## MC9, table "Named error tags": a `TypeError` is a bad request (URL, scheme, header), each other throw of
	## `fetch` is no response. The limit of `pf.readUpTo` is `TooLarge`.
	error : Io.Thrown -> [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge]
	error = |t|
		if t.name == "TooLarge" {
			TooLarge
		} else if t.name == "TypeError" {
			HttpErr(t)
		} else {
			Network(t)
		}
}

## One program: the `RequestInit` (with `AbortSignal.timeout` when there is a timeout), `fetch`, then the body to the
## limit (`pf.readUpTo`) or as a stream, and a record of the status, the headers and the body.
ops : Request, [Read(U64), Keep], Try(U64, [MissingField]), Try(Js, [MissingField]) -> List(Js.Op)
ops = |req, body_mode, timeout, cf| {
	base = [
		("method", Lit(Text(req.method.to_str()))),
		("headers", Lit(Arr(req.headers.map(|h| Arr([Text(h.name), Text(h.value)]))))),
	]
	with_body = match req.body {
		Empty => base
		Text(s) => base.append(("body", Lit(Text(s))))
		Bytes(b) => base.append(("body", Lit(Bytes(b))))
		Stream(r) => base.append(("body", Lit(Ref(r))))
	}
	with_cf = match cf {
		Ok(v) => with_body.append(("cf", Lit(v)))
		Err(_) => with_body
	}
	# Slots: the signal ops (0 or 2), the init, the response `f`.
	(signal_ops, init) = match timeout {
		Ok(ms) => (
			[Get(Root("global"), "AbortSignal"), Call(Slot(0), "timeout", [Lit(Int(ms.to_i64_try() ?? I64.highest))])],
			with_cf.append(("signal", Slot(1))),
		)
		Err(_) => ([], with_cf)
	}
	n = signal_ops.len().to_u32_wrap()
	f = n + 1
	request_ops = signal_ops.concat([Record(init), Call(Root("global"), "fetch", [Lit(Text(req.url)), Slot(n)])])
	read_ops = match body_mode {
		Read(max) => [
			Get(Slot(f), "body"),
			Call(Root("pf"), "readUpTo", [Slot(f + 1), Lit(Int(max.to_i64_try() ?? I64.highest))]),
			Get(Slot(f), "status"),
			Get(Slot(f), "headers"),
			Record([("status", Slot(f + 3)), ("headers", Slot(f + 4)), ("body", Slot(f + 2))]),
		]
		Keep => [Fields(Slot(f), ["status", "headers", "body"])]
	}
	request_ops.concat(read_ops)
}

read : Try(Js, Io.Thrown) -> Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge])
read = |r| match r {
	Ok(v) => Ok(response_of(v))
	Err(t) => Err(Http.error(t))
}

## The record of the program as a `Response`. A shape that is not that record is a platform bug: a crash.
response_of : Js -> Response
response_of = |v| match v {
	Obj(fields) => {
		status = match field(fields, "status") {
			Int(i) => i.to_u16_try() ?? crash "Http: the status ${i.to_str()} is out of range"
			other => crash "Http: the status is ${Str.inspect(other)}"
		}
		headers = match field(fields, "headers") {
			Arr(items) => items.map(
				|h| match h {
					Arr([Text(name), Text(value)]) => Header.{ name, value }
					other => crash "Http: a header is ${Str.inspect(other)}"
				},
			)
			other => crash "Http: the headers are ${Str.inspect(other)}"
		}
		body = match field(fields, "body") {
			Undefined | Null => Empty
			Bytes(b) => if b.is_empty() Empty else Bytes(b)
			Ref(r) => Stream(r)
			other => crash "Http: the body is ${Str.inspect(other)}"
		}
		Response.{ status, headers, body }
	}
	other => crash "Http: the response is ${Str.inspect(other)}"
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

expect Http.error({ name: "TypeError", message: "Invalid URL" }) == HttpErr({ name: "TypeError", message: "Invalid URL" })
expect Http.error({ name: "Error", message: "Network connection lost." }) == Network({ name: "Error", message: "Network connection lost." })
expect Http.error({ name: "TooLarge", message: "" }) == TooLarge
