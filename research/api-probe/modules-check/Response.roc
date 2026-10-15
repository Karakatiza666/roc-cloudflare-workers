import Body

## An HTTP response. One type for the response of a handler and of `Http.send!`.
## `web_socket`: the client end of a WebSocket in a 101 response, as a ref (MODULES.md 4).
Response := { status : U16, headers : List((Str, Str)), body : Body, web_socket ?: U32 }.{
	from_status : U16 -> Response
	from_status = |status| { status, headers: [], body: Body.Empty }

	from_text : U16, Str -> Response
	from_text = |status, text| { status, headers: [("content-type", "text/plain; charset=utf-8")], body: Body.Text(text) }

	from_json : U16, a -> Response where [a.Json.Encodable([])]
	from_json = |status, v| { status, headers: [("content-type", "application/json")], body: Body.Text(Json.to_str(v)) }

	with_body : Response, Str -> Response
	with_body = |r, text| { ..r, body: Body.Text(text) }

	with_header : Response, Str, Str -> Response
	with_header = |r, k, v| { ..r, headers: r.headers.append((k, v)) }

	json! : Response => Try(a, [TooLarge, BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |r| r.body.json!()

	summary : Response -> Str
	summary = |r| {
		body = match r.body {
			Text(t) => t
			_ => ""
		}
		ws = match r.?web_socket {
			Ok(_) => " (web_socket)"
			Err(_) => ""
		}
		"${r.status.to_str()} ${body}${ws}"
	}
}
