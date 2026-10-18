app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): a method with no errors (`[]`): call! and Str.inspect of its result.
import pf.Worker
import pf.Rpc
import pf.Service
import pf.Response

ping : Rpc({}, U64, [])
ping = Rpc.method("ping")

ping! : {}, {} => Try(U64, [])
ping! = |{}, {}| Ok(1)

fetch! = |_req| Ok(Response.from_text(200, Str.inspect(Service.binding("SELF").call!(ping, {}))))

worker = Worker.new({ fetch!, rpc: [ping.on(ping!)] })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
