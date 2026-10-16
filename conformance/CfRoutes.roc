## `Request.Cf` (MODULES.md 4, PLAN.md 8c): a field that Miniflare sets is `Ok`, a field that it does not set is
## `Err(Missing)`. `run.mjs` gives Miniflare a cf with `colo` and with no `metroCode`.
import pf.Request
import pf.Response

CfRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		[] => Response.from_text(
			200,
			match req.?cf {
				Ok(cf) => "colo=${Str.inspect(cf.colo)} metro_code=${Str.inspect(cf.metro_code)} asn=${Str.inspect(cf.asn)} is_eu_country=${Str.inspect(cf.is_eu_country)}"
				Err(_) => "no cf"
			},
		)
		_ => Response.from_text(404, "no route")
	}
}
