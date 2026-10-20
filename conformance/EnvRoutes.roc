## `Env` and `Secret` (MODULES.md 10). `?name=` is the name of the var. The bindings are in `checks/env.mjs`.
import pf.Request
import pf.Response
import pf.Env
import pf.Secret
import Q

Pkg : { name : Str, n : U64 }

EnvRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		name = Q.text(req, "name")
		match path {
			["var"] => ok(Str.inspect(Env.var!(name)))
			["json"] => {
				got : Try(Pkg, [Infra([MissingEnv(Str), BadData(Str)])])
				got = Env.json!(name)
				ok(
					match got {
						Ok(p) => "Ok ${p.name} ${p.n.to_str()}"
						Err(Infra(MissingEnv(n))) => "MissingEnv ${n}"
						Err(Infra(BadData(_))) => "BadData"
					},
				)
			}
			["secret"] => ok(
				match Env.secret!(name) {
					Ok(s) => "inspect=${Str.inspect(s)} reveal=${s.reveal()}"
					Err(e) => Str.inspect(e)
				},
			)
			# `Secret.from_str`, `to_inspect` and `reveal` with no binding.
			["from_str"] => {
				s = Secret.from_str(name)
				ok("inspect=${Str.inspect({ token: s })} reveal=${s.reveal()}")
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)
