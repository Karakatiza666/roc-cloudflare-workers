app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

Counter := []

api : Rpc.Iface(Counter)
api = Rpc.iface("Counter")

peek : Rpc(Counter, {}, I64, Rpc.NoErr)
peek = api.method("peek")

# no annotation on the class
counter = Object.class("Counter", { rpc: [peek.on(|_self, {}| Ok(1))] })
counters = Object.namespace("COUNTERS", { class: counter })

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	n = counters.named("a").call!(peek, {})?
	Ok(Response.from_text(200, n.to_str()))
}

worker = Worker.new({ fetch!: fetch!, objects: [counter.erase()] })

event! = |e| worker.event!(e)
