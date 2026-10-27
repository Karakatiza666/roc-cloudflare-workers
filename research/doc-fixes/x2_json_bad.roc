app [event!] { pf: platform "../../platform/main.roc" }

## X2 probe: an unannotated `req.json!()?` whose use does not fix the type (it goes on to `from_json`).
import pf.Worker
import pf.Request
import pf.Response

fetch! : Request => Try(Response, _)
fetch! = |req| {
	body = req.json!()?
	Ok(Response.from_json(200, body))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
