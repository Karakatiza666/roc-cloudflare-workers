## `Body.chunk!` and `chunk_with!` (MODULES.md 4, "Chunks"). `checks/body.mjs`. The body of a route is the request
## body (`/body/read`), or the body of `Http.open!(url)` (`/body/open?url=`). The query: `fill` and `max` give
## `chunk_with!({ fill_bytes, max_bytes })` (a missing one is not in the record), none of them gives `chunk!`.
## The answer: "sizes=<s1,s2,...> at=<ms1,...> bytes=<b> bad=<n> again=<the call after End>". Byte i of the body
## of the local server is i % 251, so `bad` counts the bytes that are not in their place (`check=0`: no count, for the
## measure of `research/chunk-fill`).
import pf.Request
import pf.Response
import pf.Body
import pf.Http
import pf.Time
import Q

BodyRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		["read"] => read!(req, req.body())
		["open"] => match Http.open!(Request.get(Q.text(req, "url"))) {
			Ok(res) => read!(req, res.body())
			Err(e) => Response.from_text(500, Str.inspect(e))
		}
		# One chunk, then `bytes!` of the rest: "first=<size> rest=<size> bad=<n>".
		["mixed"] => match Http.open!(Request.get(Q.text(req, "url"))) {
			Ok(res) => {
				body = res.body()
				first = match next!(req, body) {
					Ok(Chunk(b)) => b
					Ok(End) => []
					Err(e) => return Response.from_text(500, Str.inspect(e))
				}
				rest = match body.bytes_with!({ max_bytes: 100_000_000 }) {
					Ok(b) => b
					Err(e) => return Response.from_text(500, Str.inspect(e))
				}
				Response.from_text(200, "first=${first.len().to_str()} rest=${rest.len().to_str()} bad=${misplaced(first.concat(rest), 0).to_str()}")
			}
			Err(e) => Response.from_text(500, Str.inspect(e))
		}
		_ => Response.from_text(404, "no route")
	}
}

## `chunk_with!` with the options of the query, or `chunk!`.
next! : Request, Body => Try([Chunk(List(U8)), End], [BodyErr(_)])
next! = |req, body| {
	fill = req.query("fill")
	max = req.query("max")
	match (fill, max) {
		(Ok(_), Ok(_)) => body.chunk_with!({ fill_bytes: Q.num(req, "fill"), max_bytes: Q.num(req, "max") })
		(Ok(_), Err(_)) => body.chunk_with!({ fill_bytes: Q.num(req, "fill") })
		(Err(_), Ok(_)) => body.chunk_with!({ max_bytes: Q.num(req, "max") })
		(Err(_), Err(_)) => body.chunk!()
	}
}

## Each chunk to the end, then one call more.
read! : Request, Body => Response
read! = |req, body| {
	start = Time.now_ms!()
	count = Q.text(req, "check") != "0"
	var $sizes = []
	var $at = []
	var $bytes = 0.U64
	var $bad = 0.U64
	var $more = Bool.True
	while $more {
		match next!(req, body) {
			Ok(Chunk(b)) => {
				$bad = if (count) $bad + misplaced(b, $bytes) else $bad
				$bytes = $bytes + b.len()
				$sizes = $sizes.append(b.len().to_str())
				$at = $at.append((Time.now_ms!() - start).to_str())
			}
			Ok(End) => {
				$more = Bool.False
			}
			Err(e) => return Response.from_text(500, Str.inspect(e))
		}
	}
	again = match next!(req, body) {
		Ok(End) => "End"
		Ok(Chunk(b)) => "Chunk(${b.len().to_str()})"
		Err(_) => "Err"
	}
	Response.from_text(200, "sizes=${Str.join_with($sizes, ",")} at=${Str.join_with($at, ",")} bytes=${$bytes.to_str()} bad=${$bad.to_str()} again=${again}")
}

## The bytes of `b` that are not i % 251, where i is the place in the body (`from` is the place of the first byte).
misplaced : List(U8), U64 -> U64
misplaced = |b, from| b.fold((0.U64, from), |(n, i), x| (if (x.to_u64() == i % 251) n else n + 1, i + 1)).0
