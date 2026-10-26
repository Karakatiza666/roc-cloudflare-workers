app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

Counter := []

iface : Rpc.Iface(Counter)
iface = Rpc.iface("Counter")

get_it : Rpc(Counter, {}, Try(U64, [Missing]), [Infra(Rpc.Infra)])
get_it = iface.method("get_it")

counter : Object.Class(Counter)
counter = Object.class("Counter", { rpc: [get_it.on(|_self, _| Ok(Ok(1)))] })

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({ fetch!: fetch!, objects: [counter.erase()] })

event! = |e| worker.event!(e)
