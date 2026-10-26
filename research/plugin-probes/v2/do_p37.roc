app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object

alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, _)
alarm! = |_self, _info| Ok({})

room = Object.class("Room", {
	fetch!: |_self, _req| Ok(Response.from_status(200)),
})

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
