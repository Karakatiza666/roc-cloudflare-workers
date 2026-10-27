app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe, the fix: annotate the binding of the read.
import pf.Worker
import pf.Request
import pf.Response

Ask : { name : Str }

fetch! : Request => Try(Response, _)
fetch! = |req| {
	body : Ask
	body = req.json!()?
	Ok(Response.from_json(200, body))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
