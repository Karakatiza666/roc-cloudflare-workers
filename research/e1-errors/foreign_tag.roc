app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): a handler that gives a tag that is not in the `err` of its `Rpc` does not compile.
import pf.Worker
import pf.Rpc
import pf.Response

close_out : Rpc({}, U64, [StillOpen])
close_out = Rpc.method("close_out")

fetch! = |_req| Ok(Response.from_text(200, "x"))

close_out! = |{}, {}| Err(Busy)

worker = Worker.new({ fetch!, rpc: [close_out.on(close_out!)] })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
