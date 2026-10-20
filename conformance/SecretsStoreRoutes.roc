## `SecretsStore` (MODULES.md 13). `?name=` is the binding: `KEY` has the value `s3cr3t` (`checks/secretsstore.mjs` sets it),
## `NOKEY` has none. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.SecretsStore
import pf.Io
import pf.Secret
import Q

SecretsStoreRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		s = SecretsStore.binding(Q.text(req, "name"))
		match path {
			["get"] => show(s.get!())
			["get_io"] => show(Io.run!(s.get()))
			_ => Response.from_text(404, "no route")
		}
	}
}

show : Try(Secret, [Infra([SecretsStoreErr({ name : Str, message : Str })])]) -> Response
show = |r| Response.from_text(
	200,
	match r {
		Ok(s) => "Ok inspect=${Str.inspect(s)} reveal=${s.reveal()}"
		Err(Infra(SecretsStoreErr(t))) => "SecretsStoreErr ${t.name}: ${t.message}"
	},
)
