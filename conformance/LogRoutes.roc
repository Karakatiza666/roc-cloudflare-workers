## `Log` (MODULES.md 11): one JSON line for each call. `run.mjs` reads the lines of workerd. `?id=` makes the line unique.
import pf.Request
import pf.Response
import pf.Log
import Q

LogRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		id = Q.text(req, "id")
		match path {
			["info"] => {
				Log.info!("conformance ${id}", { route: "info", n: 7.U64 })
				ok("logged")
			}
			["warn"] => {
				Log.warn!("conformance ${id}", { route: "warn", n: 8.U64 })
				ok("logged")
			}
			["error"] => {
				Log.error!("conformance ${id}", { route: "error", n: 9.U64 })
				ok("logged")
			}
			# A record with an `F64` field is in the line; a `NaN` gives `fields_error` (a log line never fails).
			["f64"] => {
				Log.info!("conformance ${id}", { route: "f64", r: 0.5.F64 })
				ok("logged")
			}
			["f64_nan"] => {
				Log.warn!("conformance ${id}", { route: "f64_nan", r: 0.0.F64 / 0.0.F64 })
				ok("logged")
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)
