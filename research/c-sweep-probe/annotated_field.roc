app [event!] { pf: platform "../../platform/main.roc" }

## Issue 7: a field read on an annotated `Request` and on a `Response` of `Http.get!`. Both must fail at the read.
import pf.Worker
import pf.Request
import pf.Response
import pf.Http

fetch! : Request => Try(Response, _)
fetch! = |req| {
	res = Http.get!(req.url)?
	Ok(Response.from_text(200, res.status.to_str()))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
