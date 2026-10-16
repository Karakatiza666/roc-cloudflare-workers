## `Version` (MODULES.md 13). `?name=` is the binding: `V` is the local version metadata of Miniflare (`checks/version.mjs`),
## `STUB_VERSION` the JS stub of `conformance/bindings.js` with known values.
import pf.Request
import pf.Response
import pf.Version
import Q

VersionRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		["metadata"] => {
			m = Version.binding(Q.text(req, "name")).metadata!()
			Response.from_text(200, "${m.id} tag=${m.tag} ts=${m.timestamp_ms.to_str()}")
		}
		_ => Response.from_text(404, "no route")
	}
}
