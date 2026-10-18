app [event!] { pf: platform "../../platform/main.roc" }

## Probe (8h wave B, b1-body): the result of `cache.put!` is the response to send. A statement that drops it, and
## `Ctx.wait_until!` of the `cache.put` twin, must not compile.
import pf.Worker
import pf.Request
import pf.Response
import pf.Cache
import pf.Ctx

fetch! : Request => Try(Response, _)
fetch! = |req| {
	res = Response.from_body(200, "text/plain", req.body)
	cache = Cache.default
	cache.put!("https://x/a", res)?
	Ctx.wait_until!(cache.put("https://x/b", res))
	Ok(res)
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
