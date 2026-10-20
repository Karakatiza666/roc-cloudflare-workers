app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `broadcast!` gives `{}`, not a count (use `broadcast_with!`).
import pf.Worker
import pf.Object
import pf.Response
import pf.WebSocket

notify! : Object.Self => U64
notify! = |self| self.broadcast!(Text("hi"))

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
