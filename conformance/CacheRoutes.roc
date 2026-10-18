## `Cache` (MODULES.md 5.4, PLAN.md 8c). `?url=` is the key, `?name=` a named cache (else the default one). Each route
## answers `Ok <text>` or `Err <the error>`. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.Cache
import pf.Io
import pf.Http
import Q

CacheRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		url = Q.text(req, "url")
		cache = if Q.text(req, "name") == "" Cache.default else Cache.named(Q.text(req, "name"))
		match path {
			["get"] => show_get!(cache.get!(url))
			["get_io"] => show_get!(Io.run!(cache.get(url)))
			["put"] => show(cache.put!(url, made(req)), |_| "put")
			["put_io"] => show(Io.run!(cache.put(url, made(req))), |_| "put")
			# A `Stream` body: the body of a `fetch` of `?from=` is put as it is.
			["put_stream"] => match Http.open!(Request.get(Q.text(req, "from"))) {
				Ok(res) => show(cache.put!(url, res.with_header("cache-control", "max-age=60")), |_| "put")
				Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
			}
			# 8h wave B: `put!` and `put_after!` give the response to send: the route sends it.
			["put_send"] => sent(cache.put!(url, with_cc(Http.open!(Request.get(Q.text(req, "from"))))))
			["put_after"] => sent(cache.put_after!(url, with_cc(Http.open!(Request.get(Q.text(req, "from"))))))
			["delete"] => show(cache.delete!(url), |_| "deleted")
			["delete_io"] => show(Io.run!(cache.delete(url)), |_| "deleted")
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try(a, e), (a -> Str) -> Response
show = |r, f| Response.from_text(
	200,
	match r {
		Ok(v) => "Ok ${f(v)}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

## The response to put: `status` (default 200), `text`, and the header `cache-control` from `cc` (the cache needs it).
made : Request -> Response
made = |req| {
	status = if Q.text(req, "status") == "" 200 else Q.num(req, "status").to_u16_wrap()
	base = Response.from_text(status, Q.text(req, "text"))
	if Q.text(req, "cc") == "" base else base.with_header("cache-control", Q.text(req, "cc"))
}

## A hit: its status, its `cache-control` header and its body (a stream, `text!` is one more wait).
show_get! : Try(Response, [NotFound, CacheErr(Io.Thrown)]) => Response
show_get! = |r| match r {
	Ok(res) => match res.text!() {
		Ok(text) => Response.from_text(200, "Ok ${res.status().to_str()} cc=${res.header("cache-control") ?? "none"} text=${text}")
		Err(e) => Response.from_text(200, "Err body ${Str.inspect(e)}")
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## The response to send, or the error as text.
sent : Try(Response, e) -> Response
sent = |r| match r {
	Ok(res) => res
	Err(e) => Response.from_text(500, "Err ${Str.inspect(e)}")
}

## A response with a cache-control header, or an error response when the fetch failed.
with_cc : Try(Response, e) -> Response
with_cc = |r| match r {
	Ok(res) => res.with_header("cache-control", "max-age=60")
	Err(e) => Response.from_text(500, "fetch Err ${Str.inspect(e)}")
}
