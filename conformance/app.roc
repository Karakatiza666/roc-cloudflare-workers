app [event!] { pf: platform "../bench/platform/main.roc" }

## The conformance app (PLAN.md 8c): one route for each function of a module and for its `Io` twin. `run.mjs` runs it
## in Miniflare and checks each answer. A route is `/<module>/<function>`. Each module has its routes in its own file
## (`<Module>Routes.roc`, a function `route!`) and one line below. README.md says how to add a module.
import pf.Worker
import pf.Request
import pf.Response
import HttpRoutes
import EnvRoutes
import TimeRoutes
import LogRoutes
import RateLimitRoutes
import CfRoutes
import ShimRoutes
import R2Routes
import CacheRoutes

fetch! : Request => Try(Response, [])
fetch! = |req| {
	res = match req.segments() {
		["http", .. as rest] => HttpRoutes.route!(req, rest)
		["env", .. as rest] => EnvRoutes.route!(req, rest)
		["time", .. as rest] => TimeRoutes.route!(req, rest)
		["log", .. as rest] => LogRoutes.route!(req, rest)
		["ratelimit", .. as rest] => RateLimitRoutes.route!(req, rest)
		["cf", .. as rest] => CfRoutes.route!(req, rest)
		["shim", .. as rest] => ShimRoutes.route!(req, rest)
		["r2", .. as rest] => R2Routes.route!(req, rest)
		["cache", .. as rest] => CacheRoutes.route!(req, rest)
		_ => Response.from_text(404, "no route")
	}
	Ok(res)
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
