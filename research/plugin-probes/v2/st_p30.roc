app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.R2

files = R2.binding("FILES")

fetch! : Request => Try(Response, _)
fetch! = |req| {
	_ = files.put!("k", "hello")?
	_ = files.put!("k", req.body)?
	obj = files.get!("k")?
	Ok(Response.from_text(200, obj.meta.http.content_type))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
