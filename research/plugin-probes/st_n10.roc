app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http
import pf.Queue

store = Kv.json("STORE")
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	a : { theme : Str }
	a = store.get!("a")?
	b : List(U64)
	b = store.get!("b")?
	Ok(Response.from_text(200, "${a.theme} ${b.len().to_str()}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
