app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http
import pf.Queue

fetch! : Request => Try(Response, _)
fetch! = |req| {
	match Cache.default.get!(req.url) {
		Ok(hit) => Ok(hit)
		Err(_) => {
			res = Http.get!("https://example.com/")?
			Ctx.wait_until!(Cache.default.put(req.url, res))
			Ok(res)
		}
	}
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
