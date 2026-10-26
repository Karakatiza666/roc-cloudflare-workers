app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

Counter := []

counter_api : Rpc.Iface(Counter)
counter_api = Rpc.iface("Counter")

increment : Rpc(Counter, { by : I64 }, I64, [Infra(Rpc.Infra)])
increment = counter_api.method("increment")

counter : Object.Class(Counter)
counter = Object.class("Counter", { rpc: [increment.on(|_self, { by }| Ok(by))] })

counters = Object.namespace("COUNTERS", { class: counter })

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	by = 1.I64
	n = counters.named("a").call!(increment, { by })?
	Ok(Response.from_text(200, n.to_str()))
}

worker = Worker.new({ fetch!: fetch!, objects: [counter.erase()] })

event! = |e| worker.event!(e)
