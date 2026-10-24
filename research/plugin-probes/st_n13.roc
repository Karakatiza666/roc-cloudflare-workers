app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http
import pf.Queue

p = Kv.json("P")
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	c = p.cell("x")
	c.set_with!({ theme: "dark" }, { ttl_ms: 1000 })?
	v = c.get!()?
	Ok(Response.from_text(200, v.theme))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
