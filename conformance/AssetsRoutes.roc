## `Assets` (MODULES.md 13). The binding `ASSETS` serves `conformance/assets/` (`checks/assets.mjs`). `?path=` is the path,
## `?method=POST` sends a POST (the assets answer 405), `?etag=` sends `If-None-Match`. `fetch` and `fetch_io` read the
## body in Roc, `pass` and `pass_io` give the response as it is (a stream, no copy into wasm).
import pf.Request
import pf.Response
import pf.Assets
import pf.Io
import Q

assets = Assets.binding("ASSETS")

AssetsRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		r = request(req)
		match path {
			["fetch"] => show!(assets.fetch!(r))
			["fetch_io"] => show!(Io.run!(assets.fetch(r)))
			["pass"] => match assets.fetch!(r) {
				Ok(res) => res
				Err(Infra(AssetsErr(t))) => Response.from_text(200, "AssetsErr ${t.name}")
			}
			["pass_io"] => match Io.run!(assets.fetch(r)) {
				Ok(res) => res
				Err(Infra(AssetsErr(t))) => Response.from_text(200, "AssetsErr ${t.name}")
			}
			# A binding that is not in the config: the `Call` on undefined throws (OP7).
			["missing"] => show!(Assets.binding("NO_SUCH_ASSETS").fetch!(r))
			# A URL with no host: `fetch` throws a `TypeError`.
			["bad_url"] => show!(assets.fetch!(Request.get("/hello.txt")))
			_ => Response.from_text(404, "no route")
		}
	}
}

request : Request -> Request
request = |req| {
	url = "http://assets.local${Q.text(req, "path")}"
	base = if (Q.text(req, "method") == "POST") Request.post(url, Text("abc")) else Request.get(url)
	etag = Q.text(req, "etag")
	if (etag == "") base else base.with_header("if-none-match", etag)
}

show! : Try(Response, [Infra([AssetsErr({ name : Str, message : Str })])]) => Response
show! = |r| match r {
	Ok(res) => {
		type = res.header("content-type") ?? "-"
		body = match res.text!() {
			Ok(t) => t
			Err(e) => "Err ${Str.inspect(e)}"
		}
		Response.from_text(200, "status=${res.status().to_str()} type=${type} body=${body}")
	}
	Err(Infra(AssetsErr(t))) => Response.from_text(200, "AssetsErr ${t.name}")
}
