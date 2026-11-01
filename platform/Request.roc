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

	## The first value of a query parameter: `query_all(r, name).first()`, with `NotFound` for an empty list.
	query : Request, Str -> Try(Str, [NotFound])
	query = |r, name| match r.query_all(name) {
		[v, ..] => Ok(v)
		[] => Err(NotFound)
	}

	## Each value of a query parameter, in URL order (`URLSearchParams.getAll`). `?short=a&short=b` gives ["a", "b"].
	query_all : Request, Str -> List(Str)
	query_all = |r, name| r.query_pairs().keep_oks(|(k, v)| if k == name Ok(v) else Err(Other))

	## Each (name, value) pair of the query, in URL order. The parse is application/x-www-form-urlencoded of the WHATWG
	## URL standard, the same as `new URL(url).searchParams` (MODULES.md 4, "Query parameters").
	query_pairs : Request -> List((Str, Str))
	query_pairs = |r| form_pairs(query_bytes(r.url))

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

## The query of a URL as bytes, as the WHATWG URL parser finds it: no tab, LF or CR, no C0 control or space at the end,
## after the first `?` that is before the first `#`. No `?` gives no bytes.
query_bytes : Str -> List(U8)
query_bytes = |url| {
	clean = url.to_utf8().drop_if(|b| b == 0x09 or b == 0x0A or b == 0x0D)
	var $end = clean.len()
	while $end > 0 and (clean.get($end - 1) ?? 0) <= 0x20 {
		$end = $end - 1
	}
	no_frag = match clean.take_first($end).split_first('#') {
		Ok(p) => p.before
		Err(_) => clean.take_first($end)
	}
	match no_frag.split_first('?') {
		Ok(p) => p.after
		Err(_) => []
	}
}

## application/x-www-form-urlencoded parsing (WHATWG URL standard 5.1): split on `&`, skip an empty part, the name is
## before the first `=` (no `=`: all of it, and the value is empty), then `form_decode` each.
form_pairs : List(U8) -> List((Str, Str))
form_pairs = |bytes| {
	var $out = []
	for part in bytes.split_on('&') {
		if !part.is_empty() {
			$out = $out.append(
				match part.split_first('=') {
					Ok({ before, after }) => (form_decode(before), form_decode(after))
					Err(_) => (form_decode(part), "")
				},
			)
		}
	}
	$out
}

## "+" is a space, then percent-decoding: "%" and two hex digits is one byte, another "%" stays as it is. Then UTF-8
## decoding with replacement (`utf8_lossy`).
form_decode : List(U8) -> Str
form_decode = |bytes| {
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
	utf8_lossy($out)
}

## UTF-8 decode without BOM (WHATWG Encoding standard): each maximal bad part is one U+FFFD, and the byte that ends it
## is read again. A BOM stays.
utf8_lossy : List(U8) -> Str
utf8_lossy = |bytes| match Str.from_utf8(bytes) {
	Ok(s) => s
	Err(_) => {
		n = bytes.len()
		var $out = List.with_capacity(n + 8)
		var $i = 0
		while $i < n {
			b = bytes.get($i) ?? 0
			match utf8_lead(b) {
				Ascii => {
					$out = $out.append(b)
					$i = $i + 1
				}
				Bad => {
					$out = $out.concat([0xEF, 0xBF, 0xBD])
					$i = $i + 1
				}
				Lead(need, lo, hi) => {
					var $k = 1
					var $good = Bool.True
					while $good and $k <= need {
						c = bytes.get($i + $k) ?? 0
						(l, h) = if $k == 1 (lo, hi) else (0x80, 0xBF)
						if c >= l and c <= h {
							$k = $k + 1
						} else {
							$good = Bool.False
						}
					}
					if $good {
						$out = $out.concat(bytes.sublist({ start: $i, len: need + 1 }))
						$i = $i + need + 1
					} else {
						$out = $out.concat([0xEF, 0xBF, 0xBD])
						$i = $i + $k
					}
				}
			}
		}
		Str.from_utf8($out) ?? ""
	}
}

## The kind of a first byte of UTF-8: the count of bytes after it, and the range of the second byte.
utf8_lead : U8 -> [Ascii, Lead(U64, U8, U8), Bad]
utf8_lead = |b| {
	if b <= 0x7F {
		Ascii
	} else if b >= 0xC2 and b <= 0xDF {
		Lead(1, 0x80, 0xBF)
	} else if b == 0xE0 {
		Lead(2, 0xA0, 0xBF)
	} else if b == 0xED {
		Lead(2, 0x80, 0x9F)
	} else if b >= 0xE1 and b <= 0xEF {
		Lead(2, 0x80, 0xBF)
	} else if b == 0xF0 {
		Lead(3, 0x90, 0xBF)
	} else if b >= 0xF1 and b <= 0xF3 {
		Lead(3, 0x80, 0xBF)
	} else if b == 0xF4 {
		Lead(3, 0x80, 0x8F)
	} else {
		Bad
	}
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
# Query parameters: application/x-www-form-urlencoded (WHATWG URL 5.1). Each answer is `[...new URL(u).searchParams]` of Node.
qp = |u| Request.get(u).query_pairs()
expect qp("https://x.dev/p?a=1&a=2") == [("a", "1"), ("a", "2")]
expect qp("https://x.dev/p?=x&y") == [("", "x"), ("y", "")]
expect qp("https://x.dev/p?&&a&") == [("a", "")]
expect qp("https://x.dev/p?a=b=c") == [("a", "b=c")]
expect qp("https://x.dev/p?a+b=c+d") == [("a b", "c d")]
expect qp("https://x.dev/p?a=%2B&b=%2b") == [("a", "+"), ("b", "+")]
expect qp("https://x.dev/p?a=%&b=%zz&c=%4") == [("a", "%"), ("b", "%zz"), ("c", "%4")]
expect qp("https://x.dev/p?e=%C3%A9") == [("e", "é")]
expect qp("https://x.dev/p?f=%FF&g=%E2%82&h=%E2%82A") == [("f", "\u(FFFD)"), ("g", "\u(FFFD)"), ("h", "\u(FFFD)A")]
expect qp("https://x.dev/p?h=%ED%A0%80&i=%F0%90%80&j=%C0%AF") == [("h", "\u(FFFD)\u(FFFD)\u(FFFD)"), ("i", "\u(FFFD)"), ("j", "\u(FFFD)\u(FFFD)")]
expect qp("https://x.dev/p?k=%F4%90%80%80&l=%f0%9f%98%80") == [("k", "\u(FFFD)\u(FFFD)\u(FFFD)\u(FFFD)"), ("l", "\u(1F600)")]
expect qp("https://x.dev/p?%EF%BB%BFk=v") == [("\u(FEFF)k", "v")]
expect qp("https://x.dev/p?j=a;b=c") == [("j", "a;b=c")]
expect qp("https://x.dev/p#x?a=1") == []
expect qp("https://x.dev/p?a=1#b=2") == [("a", "1")]
expect qp("https://x.dev/p?a=1\tb=2\n") == [("a", "1b=2")]
expect qp("https://x.dev/p?a=1  ") == [("a", "1")]
expect qp("https://x.dev/p") == []
expect Request.get("https://x.dev/p?short=a&x=1&short=b").query_all("short") == ["a", "b"]
expect Request.get("https://x.dev/p?short=a&x=1&short=b").query_all("y") == []
expect Request.get("https://x.dev/p?short=a&x=1&short=b").query("short") == Ok("a")
expect Request.get("https://x.dev/p?=e").query("") == Ok("e")
expect Request.get("https://x.dev/p?a&&b").query("") == Err(NotFound)
expect Request.get("https://x.dev/").with_header("Cookie", "a=1; sid=xyz").cookie("sid") == Ok("xyz")
expect Request.get("https://x.dev/").with_header("X-Id", "7").header("x-id") == Ok("7")
