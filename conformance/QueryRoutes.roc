## `Request.query`, `query_all` and `query_pairs` (MODULES.md 4, "Query parameters"). `checks/query.mjs` compares each
## answer with `new URL(url).searchParams` of Node.
import pf.Request
import pf.Response

QueryRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		# The query of this request (the URL as Miniflare gives it).
		["parse"] => Response.from_json(200, parse(req))
		# The body is a URL: the query of `Request.get(body)` (a fragment, a tab: a URL that HTTP does not send).
		["of"] => match req.text!() {
			Ok(u) => Response.from_json(200, parse(Request.get(u)))
			Err(e) => Response.from_text(500, Str.inspect(e))
		}
		_ => Response.from_text(404, "no route")
	}
}

## The pairs, and for each name (and for a name that is not there): `query_all` and `query` (`[]` for `NotFound`).
parse : Request -> { pairs : List(List(Str)), names : List({ name : Str, all : List(Str), first : List(Str) }) }
parse = |req| {
	pairs = req.query_pairs()
	var $names = []
	for (k, _) in pairs {
		if !$names.contains(k) {
			$names = $names.append(k)
		}
	}
	{
		pairs: pairs.map(|(k, v)| [k, v]),
		names: $names.append("__none__").map(
			|n| {
				name: n,
				all: req.query_all(n),
				first: match req.query(n) {
					Ok(v) => [v]
					Err(NotFound) => []
				},
			},
		),
	}
}
