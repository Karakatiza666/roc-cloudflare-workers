## `Response.after` (MODULES.md 4, API.md 10.2) in a Worker `fetch!` and in a named entry point (`After`). `?id=` names the
## keys of the effect in the namespace `KV`. `?url=` is a slow URL (the local server of `run.mjs`).
import pf.Request
import pf.Response
import pf.Http
import pf.Kv
import pf.Time
import pf.Rpc
import pf.Service
import Q

store : Kv(Str)
store = Kv.text("KV")

after_service = Service.binding("AFTER")

AfterRoutes :: [].{

	## The named entry points of this module.
	entrypoints : List(Rpc.Entrypoint)
	entrypoints = [Rpc.entrypoint("After", { fetch!: entry_fetch! })]

	route! : Request, List(Str) => Response
	route! = |req, path| {
		id = Q.text(req, "id")
		match path {
			# The work waits on a slow fetch, then writes a key. The client has the response before the fetch ends.
			["slow"] => Response.from_text(200, "early").after(slow_work!(Q.text(req, "url"), "after-${id}"))
			# The same in a named entry point, reached by a service binding.
			["entry"] => match after_service.fetch!(Request.get("http://x/?url=${Q.text(req, "url")}&id=${id}")) {
				Ok(res) => res
				Err(e) => Response.from_text(500, Str.inspect(e))
			}
			# A work that fails in a named entry point: the log line has the name of the entry point (`After.fetch: ...`).
			["entry_fail"] => match after_service.fetch!(Request.get("http://x/?fail=1&id=${id}")) {
				Ok(res) => res
				Err(e) => Response.from_text(500, Str.inspect(e))
			}
			# Two `after` calls: the second work reads what the first one wrote.
			["two"] => {
				first! = || {
					Time.sleep!(300)
					store.put!("after-${id}-a", "one")
				}
				second! = || {
					a = store.get_or!("after-${id}-a", "missing") ?? "error"
					store.put!("after-${id}-b", a)
				}
				Response.from_text(200, "first").after(first!).after(second!)
			}
			# A work that fails: the log line, and the client still has 200.
			["fail"] => Response.from_text(200, "ok").after(|| Err(Boom(id)))
			_ => Response.from_text(404, "no route")
		}
	}
}

slow_work! : Str, Str => (() => Try({}, _))
slow_work! = |url, key| || {
	_ = Http.send!(Request.get(url))
	store.put!(key, "done")
}

entry_fetch! : Request => Try(Response, [])
entry_fetch! = |req| {
	id = Q.text(req, "id")
	if Q.text(req, "fail") == "1" {
		Ok(Response.from_text(200, "ok").after(|| Err(Boom(id))))
	} else {
		Ok(Response.from_text(200, "early").after(slow_work!(Q.text(req, "url"), "after-${id}")))
	}
}
