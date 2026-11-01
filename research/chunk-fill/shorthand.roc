app [event!] { pf: platform "../../platform/main.roc" }

## Probe: `Worker.new({ fetch! })` with one field is a block, not a record. `roc check research/chunk-fill/shorthand.roc`: the type mismatch of MODULES.md 2.
import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "hi"))

worker = Worker.new({ fetch! })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
