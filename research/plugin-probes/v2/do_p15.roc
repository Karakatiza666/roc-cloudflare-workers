app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service

Front := []
front_api : Rpc.Iface(Front)
front_api = Rpc.iface("Front")

ping : Rpc(Front, {}, Str, Rpc.NoErr)
ping = front_api.method("ping")
front = Service.binding("FRONT", front_api)

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	s = front.call!(ping, ())?
	Ok(Response.from_text(200, s))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
