app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv
import pf.Cache
import pf.Ctx
import pf.Http

fetch! : Request => Try(Response, _)
fetch! = |req| {
	res = Http.get!("https://example.com/")?
	Cache.default.put!(req.url(), res)?
	Ctx.wait_until!(Cache.default.put(req.url(), res))
	Ok(res)
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
