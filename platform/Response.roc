## An HTTP response (MODULES.md 4). One type for the response of a handler and of `Http.send!`.
## `web_socket`: the client end of a WebSocket in a 101 response, as a ref (MC13).
import Body
import Io
import Js
import http.Header

Response := { status : U16, headers : List(Header) ?? [], body : Body ?? Empty, web_socket ?: Js.Ref }.{
	from_status : U16 -> Response
	from_status = |status| Response.{ status }

	## text/plain; charset=utf-8
	from_text : U16, Str -> Response
	from_text = |status, text| Response.{ status, headers: [content_type("text/plain; charset=utf-8")], body: Text(text) }

	## A value that JSON cannot show (a `NaN` in an `F64`) gives a 500 response with a text body that says so.
	from_json : U16, a -> Response where [a.Json.Encodable(enc)]
	from_json = |status, value| match Json.to_str_try(value) {
		Ok(text) => Response.{ status, headers: [content_type("application/json")], body: Text(text) }
		Err(e) => Response.from_text(500, "the response does not encode as JSON: ${Str.inspect(e)}")
	}

	## The Str is the content type.
	from_bytes : U16, Str, List(U8) -> Response
	from_bytes = |status, type, bytes| Response.{ status, headers: [content_type(type)], body: Bytes(bytes) }

	## A body of any kind: also a stream (an R2 body, a fetch body).
	from_body : U16, Str, Body -> Response
	from_body = |status, type, body| Response.{ status, headers: [content_type(type)], body }

	redirect : U16, Str -> Response
	redirect = |status, location| Response.{ status, headers: [Header.{ name: "location", value: location }] }

	with_header : Response, Str, Str -> Response
	with_header = |r, name, value| { ..r, headers: r.headers.append(Header.{ name, value }) }

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
