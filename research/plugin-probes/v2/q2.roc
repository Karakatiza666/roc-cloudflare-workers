app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response

helper! : Request => Try(Response, _)
helper! = |_req| Ok(Response.from_status(204))

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["a"] => helper!(req)
	_ => {
		text = req.text!()?
		Ok(Response.from_text(200, text))
	}
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
