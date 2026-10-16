## The shim: a value of the option `ops` that is an object (PLAN.md 8a O4), reached with `Get` and `Call` (API.md 6.4).
import pf.Request
import pf.Response
import pf.Io

ShimRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |_req, path| match path {
		["ops"] => Response.from_text(200, Str.inspect(Io.call!([Get(Root("ops"), "lib"), Call(Slot(0), "twice", [Lit(Int(21))])])))
		_ => Response.from_text(404, "no route")
	}
}
