app [event!] { pf: platform "../../platform/main.roc" }

## Issue 7: a wrong use in an unannotated `fetch!`. The error must be at the use, not at `Worker.new`.
import pf.Worker
import pf.Response

fetch! = |req| {
	# `method()` gives a `Method` (a tag union), not a `Str`.
	Ok(Response.from_text(200, req.method().concat(req.url())))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
