## An HTTP request, incoming or outgoing (MODULES.md 4). `Method` and `Header` come from `roc-lang/http` (AQ2).
## Opaque: read it with its methods (`req.method()`, `req.url()`, `req.headers()`, `req.body()`, `req.cf()`), and make
## it with `new`, `get`, `post` and `with_*`. `cf`: incoming only, `request.cf` typed. A field that Workers does not
## give is `Err(Missing)` (MC8).
## Typed data: the format, what a JS peer sees, and what survives a round trip are in MODULES.md 1, "Formats of typed data".
import Body
import Io
import http.Method
import http.Header

Request :: {
	method : Method,
	url : Str,
	headers : List(Header) ?? [],
	body : Body ?? Empty,
	cf ?: Request.Cf,
}.{

	## `request.cf` of Workers, typed (MODULES.md 4, the row `cf`).
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

	## A request with no headers and no body.
	new : Method, Str -> Request
	new = |m, u| Request.{ method: m, url: u }

	get : Str -> Request
	get = |u| Request.{ method: GET, url: u }

	post : Str, Body -> Request
	post = |u, b| Request.{ method: POST, url: u, body: b }

	## A value that JSON cannot show (a `NaN` in an `F64`) is `BadData`.
	post_json : Str, a -> Try(Request, [BadData(Str)]) where [a.Json.Encodable(enc)]
	post_json = |u, value| match Json.to_str_try(value) {
		Ok(text) => Ok(
			Request.{
				method: POST,
				url: u,
				headers: [Header.{ name: "content-type", value: "application/json" }],
				body: Text(text),
			},
		)
		Err(e) => Err(BadData(Str.inspect(e)))
	}

	method : Request -> Method
	method = |r| r.method

	url : Request -> Str
	url = |r| r.url

	headers : Request -> List(Header)
	headers = |r| r.headers

	body : Request -> Body
	body = |r| r.body

	## `request.cf` of an incoming request. `Missing`: an outgoing request, or a request with no `cf`.
	cf : Request -> Try(Request.Cf, [Missing])
	cf = |r| r.?cf.map_err(|_| Missing)

	with_header : Request, Str, Str -> Request
	with_header = |r, name, value| { ..r, headers: r.headers.append(Header.{ name, value }) }

	## All headers in place of the old ones.
	with_headers : Request, List(Header) -> Request
	with_headers = |r, list| { ..r, headers: list }

	with_method : Request, Method -> Request
	with_method = |r, m| { ..r, method: m }

	with_url : Request, Str -> Request
	with_url = |r, u| { ..r, url: u }

	with_body : Request, Body -> Request
	with_body = |r, b| { ..r, body: b }

	## Low level: the `cf` of an incoming request (the platform entry, a test).
	with_cf : Request, Request.Cf -> Request
	with_cf = |r, c| { ..r, cf: c }

	## The path as segments, for a `match` with a list pattern: `(GET, ["v1", "pkg", name])`.
	## "https://x/v1/packages/a/b/releases?q=1" gives ["v1", "packages", "a", "b", "releases"].
	segments : Request -> List(Str)
	segments = |r| path_of(r.url).split_on("/").keep_if(|s| s != "")

	## The first value of a query parameter, percent-decoded ("+" is a space).
	query : Request, Str -> Try(Str, [NotFound])
	query = |r, name| {
		q = match r.url.split_first("?") {
			Ok({ after, .. }) => match after.split_first("#") {
				Ok(p) => p.before
				Err(_) => after
			}
			Err(_) => return Err(NotFound)
		}
		for pair in q.split_on("&") {
			(k, v) = match pair.split_first("=") {
				Ok({ before, after }) => (before, after)
				Err(_) => (pair, "")
			}
			if decode(k) == name {
				return Ok(decode(v))
			}
		}
		Err(NotFound)
	}

	## The value of a header. The name is caseless, as in Workers `Headers.get`.
	header : Request, Str -> Try(Str, [NotFound])
	header = |r, name| header_in(r.headers, name)

	## The value of a cookie of the `Cookie` header.
	cookie : Request, Str -> Try(Str, [NotFound])
	cookie = |r, name| {
		line = header_in(r.headers, "cookie")?
		for part in line.split_on(";") {
			match part.trim().split_first("=") {
				Ok({ before, after }) if before == name => return Ok(after)
				_ => {}
			}
		}
		Err(NotFound)
	}

	text! : Request => Try(Str, [TooLarge, BadData(Str), BodyErr(Io.Thrown)])
	text! = |r| r.body.text!()

	json! : Request => Try(a, [TooLarge, BadData(Str), BodyErr(Io.Thrown)]) where [a.Json.Parseable([InvalidJson(Str), ..errs])]
	json! = |r| r.body.json!()

	bytes! : Request => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes! = |r| r.body.bytes!()

	bytes_with! : Request, { max_bytes : U64 } => Try(List(U8), [TooLarge, BodyErr(Io.Thrown)])
	bytes_with! = |r, opts| r.body.bytes_with!(opts)
}

## A header value in a list of headers, caseless.
header_in : List(Header), Str -> Try(Str, [NotFound])
header_in = |headers, name| {
	lower = name.with_ascii_lowercased()
	match headers.find_first(|h| h.name.with_ascii_lowercased() == lower) {
		Ok(h) => Ok(h.value)
		Err(_) => Err(NotFound)
	}
}

## The path of a URL: after the authority, before `?` and `#`.
path_of : Str -> Str
path_of = |url| {
	rest = match url.split_first("://") {
		Ok({ after, .. }) => match after.split_first("/") {
			Ok(p) => p.after
			Err(_) => ""
		}
		Err(_) => url
	}
	no_query = match rest.split_first("?") {
		Ok(p) => p.before
		Err(_) => rest
	}
	match no_query.split_first("#") {
		Ok(p) => p.before
		Err(_) => no_query
	}
}

## Percent-decoding of a query part, and "+" as a space. A bad escape stays as it is.
decode : Str -> Str
decode = |s| {
	bytes = s.to_utf8()
	var $out = List.with_capacity(bytes.len())
	var $i = 0
	while $i < bytes.len() {
		b = bytes.get($i) ?? 0
		if b == '+' {
			$out = $out.append(' ')
			$i = $i + 1
		} else if b == '%' {
			match (hex(bytes.get($i + 1) ?? 0), hex(bytes.get($i + 2) ?? 0)) {
				(Ok(h), Ok(l)) => {
					$out = $out.append(h * 16 + l)
					$i = $i + 3
				}
				_ => {
					$out = $out.append(b)
					$i = $i + 1
				}
			}
		} else {
			$out = $out.append(b)
			$i = $i + 1
		}
	}
	Str.from_utf8($out) ?? s
}

hex : U8 -> Try(U8, [NotHex])
hex = |c| {
	if c >= '0' and c <= '9' {
		Ok(c - '0')
	} else if c >= 'a' and c <= 'f' {
		Ok(c - 'a' + 10)
	} else if c >= 'A' and c <= 'F' {
		Ok(c - 'A' + 10)
	} else {
		Err(NotHex)
	}
}

expect Request.get("https://x.dev/v1/packages/a/b/releases?q=1").segments() == ["v1", "packages", "a", "b", "releases"]
expect Request.get("https://x.dev").segments() == []
expect Request.get("https://x.dev/a?x=1&name=r%C3%B6c+lang&y").query("name") == Ok("röc lang")
expect Request.get("https://x.dev/a?x=1#name=2").query("name") == Err(NotFound)
expect Request.get("https://x.dev/").with_header("Cookie", "a=1; sid=xyz").cookie("sid") == Ok("xyz")
expect Request.get("https://x.dev/").with_header("X-Id", "7").header("x-id") == Ok("7")
