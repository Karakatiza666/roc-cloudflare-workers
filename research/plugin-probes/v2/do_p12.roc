app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc

Front := []
Back := []

front_api : Rpc.Iface(Front)
front_api = Rpc.iface("Front")
back_api : Rpc.Iface(Back)
back_api = Rpc.iface("Back")

lookup : Rpc(Front, { key : Str }, Str, [Unknown])
lookup = front_api.method("lookup")
other : Rpc(Back, { key : Str }, Str, [Unknown])
other = back_api.method("other")

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({
	fetch!: fetch!,
	rpc: [
		lookup.on_worker(|{ key }| if key == "a" Ok("alpha") else Err(Missing)),
		other.on_worker(|{ key }| Ok(key)),
	],
})

event! = |e| worker.event!(e)
