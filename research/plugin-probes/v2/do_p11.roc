app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service

Other := []

other_api : Rpc.Iface(Other)
other_api = Rpc.iface("Other")

lookup = other_api.method("lookup")

other = Service.binding("OTHER", other_api)

fetch! : Request => Try(Response, _)
fetch! = |req| {
	v = other.call!(lookup, { key: "a" })?
	Ok(Response.from_text(200, v))
}

worker = Worker.new({ fetch!: fetch!, rpc: [lookup.on_worker(|{ key }| Ok(key))] })

event! = |e| worker.event!(e)
