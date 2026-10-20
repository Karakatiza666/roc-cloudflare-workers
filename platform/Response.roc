## An HTTP response (MODULES.md 4). One type for the response of a handler and of `Http.send!`. Opaque: read it with
## its methods (`res.status()`, `res.headers()`, `res.body()`), and make it with `from_*` and `with_*`.
## `web_socket`: the client end of a WebSocket in a 101 response, as a ref (MC13). `after_work!`: the work that runs after
## the response is sent (`after`), with its error as text.
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Body
import Io
import Js
import http.Header

Response :: { status : U16, headers : List(Header) ?? [], body : Body ?? Empty, web_socket ?: Js.Ref, after_work! ?: () => Try({}, Str) }.{
	status : Response -> U16
	status = |r| r.status

	headers : Response -> List(Header)
	headers = |r| r.headers

	body : Response -> Body
	body = |r| r.body

	## The client end of the WebSocket of a 101 response (a ref, MC13). `Missing`: the response has none.
	web_socket : Response -> Try(Js.Ref, [Missing])
	web_socket = |r| r.?web_socket.map_err(|_| Missing)

	## Low level: the response with the client end of a WebSocket (the 101 of `WebSocket.pair!` and of a fetch).
	with_web_socket : Response, Js.Ref -> Response
	with_web_socket = |r, ws| { ..r, web_socket: ws }

	## The work of `after`, for the platform entry. `Missing`: no `after`.
	after_work : Response -> Try((() => Try({}, Str)), [Missing])
	after_work = |r| r.?after_work!.map_err(|_| Missing)

	with_status : Response, U16 -> Response
	with_status = |r, code| { ..r, status: code }

	## All headers in place of the old ones.
	with_headers : Response, List(Header) -> Response
	with_headers = |r, list| { ..r, headers: list }

	with_body : Response, Body -> Response
	with_body = |r, b| { ..r, body: b }

	from_status : U16 -> Response
	from_status = |code| Response.{ status: code }

	## text/plain; charset=utf-8
	from_text : U16, Str -> Response
	from_text = |code, text| Response.{ status: code, headers: [content_type("text/plain; charset=utf-8")], body: Text(text) }

	## A value that JSON cannot show (a `NaN` in an `F64`) gives a 500 response with a text body that says so.
	from_json : U16, a -> Response where [a.Json.Encodable(enc)]
	from_json = |code, value| match Json.to_str_try(value) {
		Ok(text) => Response.{ status: code, headers: [content_type("application/json")], body: Text(text) }
		Err(e) => Response.from_text(500, "the response does not encode as JSON: ${Str.inspect(e)}")
	}

	## The Str is the content type.
	from_bytes : U16, Str, List(U8) -> Response
	from_bytes = |code, type, bytes| Response.{ status: code, headers: [content_type(type)], body: Bytes(bytes) }

	## A body of any kind: also a stream (an R2 body, a fetch body).
	from_body : U16, Str, Body -> Response
	from_body = |code, type, b| Response.{ status: code, headers: [content_type(type)], body: b }

	redirect : U16, Str -> Response
	redirect = |code, location| Response.{ status: code, headers: [Header.{ name: "location", value: location }] }

	with_header : Response, Str, Str -> Response
	with_header = |r, name, value| { ..r, headers: r.headers.append(Header.{ name, value }) }

	## Respond now, work after (API.md 10.2): when a `fetch!` handler gives this response, the platform sends it, and
	## then runs `work!` in the same task. The client has its response already, so an `Err(e)` of `work!` cannot reach it:
	## it is the log line `fetch: after respond: failed: <Str.inspect(e)>` (`<name>.fetch: ...` in an object or a named entry point).
	## A second `after` runs after the first. Only the response of a `fetch!` handler runs its work.
	after : Response, (() => Try({}, e)) -> Response
	after = |r, work!| {
		erased! = || work!().map_err(|e| Str.inspect(e))
		match r.?after_work! {
			Ok(first!) => {
				both! = || {
					first!()?
					erased!()
				}
				{ ..r, after_work!: both! }
			}
			Err(_) => { ..r, after_work!: erased! }
		}
	}

	## The value of a header. The name is caseless.
	header : Response, Str -> Try(Str, [NotFound])
	header = |r, name| {
		lower = name.with_ascii_lowercased()
		match r.headers.find_first(|h| h.name.with_ascii_lowercased() == lower) {
			Ok(h) => Ok(h.value)
			Err(_) => Err(NotFound)
		}
	}

	text! : Response => Try(Str, [TooLarge, BadData(Str), BodyErr(Io.Thrown)])
	text! = |r| r.body.text!()

	json! : Response => Try(a, [TooLarge, BadData(Str), BodyErr(Io.Thrown)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |r| r.body.json!()

	bytes! : Response => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes! = |r| r.body.bytes!()

	bytes_with! : Response, { max_bytes : U64 } => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes_with! = |r, opts| r.body.bytes_with!(opts)
}

content_type : Str -> Header
content_type = |value| Header.{ name: "content-type", value }

expect Response.from_text(404, "no").header("Content-Type") == Ok("text/plain; charset=utf-8")
expect Response.redirect(302, "/a").header("location") == Ok("/a")
