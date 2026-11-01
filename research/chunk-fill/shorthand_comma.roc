app [event!] { pf: platform "../../platform/main.roc" }

## Probe: `Worker.new({ fetch!, })` with one field and a comma is a record. `roc check research/chunk-fill/shorthand_comma.roc`: no errors.
import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "hi"))

worker = Worker.new({ fetch!, })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
