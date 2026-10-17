## `Hyperdrive.config!` and `connect!` (MODULES.md 13). `?name=` is the binding: `PG` is the local Hyperdrive of Miniflare
## (`checks/hyperdrive.mjs`), `PGECHO` one whose origin is the TCP echo server of `checks/tcp.mjs`. The two secrets show
## only as `Secret(...)` unless the route reveals them.
import pf.Request
import pf.Response
import pf.Hyperdrive
import pf.Io
import pf.Time
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
		# `connect!` and its twin: a `Tcp` socket to the origin of the binding (PLAN.md 8f part 3).
		["connect"] => {
			h = Hyperdrive.binding(Q.text(req, "name"))
			talk! = |r| match r {
				Ok(s) => {
					w = s.write!(Str.to_utf8("hd"))
					raced = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(2_000).map(|_| TimedOut)])
					got = raced.result
					s.close!()
					"write=${Str.inspect(w)} read=${Str.inspect(got)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, "${talk!(h.connect!())} twin: ${talk!(Io.run!(h.connect()))}")
		}
		_ => Response.from_text(404, "no route")
	}
}
