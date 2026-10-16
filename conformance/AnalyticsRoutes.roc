## `Analytics` (MODULES.md 13). `?name=` is the binding: `STATS` is the local Analytics Engine dataset (it keeps nothing),
## `STUB_STATS` the JS stub of `conformance/bindings.js` that records the data point, `NOPE` is not in the config.
import pf.Request
import pf.Response
import pf.Analytics
import Q

AnalyticsRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		a = Analytics.binding(Q.text(req, "name"))
		match path {
			["write"] => show(a.write!({ blobs: ["a", "b"], doubles: [1.5, 2.0], indexes: ["i"] }))
			["write_empty"] => show(a.write!({ blobs: [], doubles: [], indexes: [] }))
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try({}, [AnalyticsErr({ name : Str, message : Str })]) -> Response
show = |r| Response.from_text(
	200,
	match r {
		Ok({}) => "Ok"
		Err(AnalyticsErr(t)) => "AnalyticsErr ${t.name}"
	},
)
