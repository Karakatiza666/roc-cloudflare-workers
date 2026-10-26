app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object

count = Object.cell("count")

room = Object.class("Room", {
	fetch!: |self, _req| {
		n = count.get_or!(self, 0)?
		Ok(Response.from_text(200, n.to_str()))
	},
})

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
