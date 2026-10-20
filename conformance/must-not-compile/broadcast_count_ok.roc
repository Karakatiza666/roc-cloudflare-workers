app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of broadcast_count_bad.roc: `broadcast!` gives `{}`, `broadcast_with!` gives the count.
import pf.Worker
import pf.Object
import pf.Response
import pf.WebSocket

notify! : Object.Self => U64
notify! = |self| {
	self.broadcast!(Text("hi"))
	self.broadcast_with!({}, Text("hi"))
}

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
