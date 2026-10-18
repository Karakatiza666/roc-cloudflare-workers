app [event!] { pf: platform "../../../platform/main.roc" }

## Probe (step 8h): a typed RPC method in a class of a type module.
import pf.Worker
import pf.Response
import M

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!, rpc: M.rpc })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
