## `Hyperdrive.config!` (MODULES.md 13). `?name=` is the binding: `PG` is the local Hyperdrive of Miniflare
## (`checks/hyperdrive.mjs`). The two secrets show only as `Secret(...)` unless the route reveals them.
import pf.Request
import pf.Response
import pf.Hyperdrive
import Q

HyperdriveRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		["config"] => {
			c = Hyperdrive.binding(Q.text(req, "name")).config!()
			Response.from_text(
				200,
				"host=${c.host} port=${c.port.to_str()} user=${c.user} database=${c.database} inspect=${Str.inspect({ cs: c.connection_string, pw: c.password })} password=${c.password.reveal()} cs=${c.connection_string.reveal()}",
			)
		}
		_ => Response.from_text(404, "no route")
	}
}
