## `RateLimit` (MODULES.md 10). `?key=` is the key. The binding `LIMITER` (2 requests in 60 s) is in `checks/ratelimit.mjs`.
import pf.Request
import pf.Response
import pf.RateLimit
import pf.Io
import Q

limiter = RateLimit.binding("LIMITER")

RateLimitRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		key = Q.text(req, "key")
		match path {
			["limit"] => show(limiter.limit!(key))
			["limit_io"] => show(Io.run!(limiter.limit(key)))
			# A binding that is not in the config: the `Call` on undefined throws (OP7).
			["missing"] => show(RateLimit.binding("NO_SUCH_LIMITER").limit!(key))
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try({}, [RateLimited, Infra([LimitErr({ name : Str, message : Str })])]) -> Response
show = |r| Response.from_text(
	200,
	match r {
		Ok({}) => "Ok"
		Err(RateLimited) => "RateLimited"
		Err(Infra(LimitErr(t))) => "LimitErr ${t.name}"
	},
)
