app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Http
import pf.Ctx
import pf.Body

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	{ body, writer } = Body.writer!({})?
	Ok(Response.from_body(200, "text/plain", body))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
