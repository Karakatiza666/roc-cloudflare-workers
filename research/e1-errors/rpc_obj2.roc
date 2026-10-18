app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): a typed RPC method on a Durable Object class.
import pf.Worker
import pf.Rpc
import pf.Object
import pf.Response

ping : Rpc({}, U64, Rpc.NoErr)
ping = Rpc.method("ping")

ping! : Object.Self, {} => Try(U64, Rpc.NoErr)
ping! = |_self, {}| Ok(1)

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!, objects: [Object.class("C", { rpc: [ping.on(ping!)] })] })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
