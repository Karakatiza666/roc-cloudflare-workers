app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Http
import pf.Ctx
import pf.Body

fetch! : Request => Try(Response, _)
fetch! = |req| {
	text = req.text!()?
	Ok(Response.from_text(202, "queued").after(|| {
		more = req.text!()?
		Ok({})
	}))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
