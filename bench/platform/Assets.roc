## The Assets binding (MODULES.md 13): `env[name].fetch(request)`, one wait. The body of the response stays a stream in
## JS (a `Stream` body, MC13), so a response of a large file goes to the client with no copy into wasm (API.md 10a): the
## usual use is `Assets.fetch!(req)` as the response. `res.bytes!()` and `text!()` read it to a limit (MC11).
## The request goes as `fetch(url, init)`, the same as `Http` (`platform/Http.roc`).
import Io
import Js
import Body
import Request
import Response
import http.Header

Assets :: { name : Str }.{
	binding : Str -> Assets
	binding = |name| Assets.{ name }

	## Each status is `Ok` (a 404 is an answer of the assets): only a throw is `AssetsErr`.
	fetch : Assets, Request -> Io(Response, [AssetsErr(Io.Thrown)])
	fetch = |a, req| Io.new(
		ops(a.name, req),
		|r| match r {
			Ok(v) => Ok(response_of(v))
			Err(t) => Err(AssetsErr(t))
		},
	)

	fetch! : Assets, Request => Try(Response, [AssetsErr(Io.Thrown)])
	fetch! = |a, req| Io.run!(fetch(a, req))
}

## Slots: 0 the binding, 1 the `RequestInit`, 2 the response, 3 its fields.
ops : Str, Request -> List(Js.Op)
ops = |name, req| {
	base = [
		("method", Lit(Text(req.method.to_str()))),
		("headers", Lit(Arr(req.headers.map(|h| Arr([Text(h.name), Text(h.value)]))))),
	]
	init = match req.body {
		Empty => base
		Text(s) => base.append(("body", Lit(Text(s))))
		Bytes(b) => base.append(("body", Lit(Bytes(b))))
		Stream(r) => base.append(("body", Lit(Ref(r))))
	}
	[
		Get(Root("env"), name),
		Record(init),
		Call(Slot(0), "fetch", [Lit(Text(req.url)), Slot(1)]),
		Fields(Slot(2), ["status", "headers", "body"]),
	]
}

## The record of the program as a `Response`. A shape that is not that record is a platform bug: a crash.
response_of : Js -> Response
response_of = |v| match v {
	Obj(fields) => {
		status = match field(fields, "status") {
			Int(i) => i.to_u16_try() ?? crash "Assets: the status ${i.to_str()} is out of range"
			other => crash "Assets: the status is ${Str.inspect(other)}"
		}
		headers = match field(fields, "headers") {
			Arr(items) => items.map(
				|h| match h {
					Arr([Text(name), Text(value)]) => Header.{ name, value }
					other => crash "Assets: a header is ${Str.inspect(other)}"
				},
			)
			other => crash "Assets: the headers are ${Str.inspect(other)}"
		}
		body = match field(fields, "body") {
			Undefined | Null => Empty
			Bytes(b) => if b.is_empty() Empty else Bytes(b)
			Ref(r) => Stream(r)
			other => crash "Assets: the body is ${Str.inspect(other)}"
		}
		Response.{ status, headers, body }
	}
	other => crash "Assets: the response is ${Str.inspect(other)}"
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

expect match ops("ASSETS", Request.get("https://x.dev/a.txt")) {
	[Get(Root("env"), "ASSETS"), Record(init), Call(Slot(0), "fetch", [Lit(Text("https://x.dev/a.txt")), Slot(1)]), Fields(Slot(2), ["status", "headers", "body"])] => init.len() == 2
	_ => Bool.False
}
# A body goes into the init as it is (text, bytes or a stream).
expect match ops("ASSETS", Request.post("https://x.dev/a", Text("abc"))) {
	[_, Record(init), _, _] => init.len() == 3
	_ => Bool.False
}
expect response_of(Obj([("status", Int(404)), ("headers", Arr([])), ("body", Null)])).status == 404
