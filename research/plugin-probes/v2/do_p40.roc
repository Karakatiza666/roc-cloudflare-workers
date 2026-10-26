app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc
import pf.Io

Counter := []

api : Rpc.Iface(Counter)
api = Rpc.iface("Counter")

Faults : [StorageErr(Io.Thrown), BadData(Str)]

peek : Rpc(Counter, {}, I64, [Infra(Faults)])
peek = api.method("peek")

count : Object.Cell(I64)
count = Object.cell("count")

counter : Object.Class(Counter)
counter = Object.class("Counter", { rpc: [peek.on(|self, {}| Ok(count.get_or!(self, 0)?))] })

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({ fetch!: fetch!, objects: [counter.erase()] })

event! = |e| worker.event!(e)
