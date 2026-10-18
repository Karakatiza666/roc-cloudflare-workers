app [event!] { pf: platform "../../platform/main.roc" }

## Issue 7: an unannotated `fetch!` that reads `req.method` (a field read). It must not compile, and the error must be at the read.
import pf.Worker
import pf.Response

fetch! = |req| {
	m = req.method
	Ok(Response.from_text(200, "${Str.inspect(m)} ${req.segments().len().to_str()}"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
