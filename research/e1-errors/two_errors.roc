app [event!] { pf: platform "../../platform/main.roc" }

## Probe (step 8h): a `fetch!` with a closed `[]` error and a `scheduled!` with a real error in one `Worker`.
import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_text(200, "ok"))

scheduled! : Worker.Scheduled => Try({}, [UnknownCron(Str)])
scheduled! = |s| Err(UnknownCron(s.cron))

worker = Worker.new({ fetch!, scheduled! })

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
