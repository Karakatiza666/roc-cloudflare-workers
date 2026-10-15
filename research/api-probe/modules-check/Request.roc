import Body
import Method

## An HTTP request, incoming or outgoing. `Method` is a copy of the one of `roc-lang/http`.
## `cf`: incoming only, `request.cf` typed (MODULES.md 4). A field that JS does not give is `Err(Missing)`.
Request := { method : Method, url : Str, headers : List((Str, Str)) ?? [], body : Body ?? Body.Empty, cf ?: Request.Cf }.{
	Cf : {
		asn : Try(U32, [Missing]),
		as_organization : Try(Str, [Missing]),
		colo : Try(Str, [Missing]),
		country : Try(Str, [Missing]),
		is_eu_country : Bool,
		city : Try(Str, [Missing]),
		continent : Try(Str, [Missing]),
		region : Try(Str, [Missing]),
		region_code : Try(Str, [Missing]),
		postal_code : Try(Str, [Missing]),
		metro_code : Try(Str, [Missing]),
		latitude : Try(Str, [Missing]),
		longitude : Try(Str, [Missing]),
		timezone : Try(Str, [Missing]),
		http_protocol : Try(Str, [Missing]),
		tls_version : Try(Str, [Missing]),
		tls_cipher : Try(Str, [Missing]),
		client_tcp_rtt_ms : Try(U64, [Missing]),
	}

	get : Str -> Request
	get = |url| Request.{ method: GET, url }

	post_json : Str, a -> Request where [a.Json.Encodable([])]
	post_json = |url, v| {
		method: POST,
		url,
		headers: [("content-type", "application/json")],
		body: Body.Text(Json.to_str(v)),
	}

	with_header : Request, Str, Str -> Request
	with_header = |r, k, v| { ..r, headers: r.headers.append((k, v)) }

	## The path as segments, for a `match` on a list pattern: `(GET, ["v1", "pkg", name])`.
	segments : Request -> List(Str)
	segments = |r| {
		path = match r.url.split_first("://") {
			Ok({ after, .. }) => match after.split_first("/") {
				Ok(p) => p.after
				Err(_) => ""
			}
			Err(_) => r.url
		}
		no_query = match path.split_first("?") {
			Ok(p) => p.before
			Err(_) => path
		}
		no_query.split_on("/").keep_if(|s| s != "")
	}

	## Case-insensitive, as in Workers `Headers.get`.
	header : Request, Str -> Try(Str, [NotFound])
	header = |r, name| {
		lower = name.with_ascii_lowercased()
		match r.headers.find_first(|(k, _)| k.with_ascii_lowercased() == lower) {
			Ok((_, v)) => Ok(v)
			Err(_) => Err(NotFound)
		}
	}

	json! : Request => Try(a, [TooLarge, BadData(Str)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |r| r.body.json!()
}
