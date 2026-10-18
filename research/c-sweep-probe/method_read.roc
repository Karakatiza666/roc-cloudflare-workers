app [event!] { pf: platform "../../platform/main.roc" }

## Issue 7: the same `fetch!` with the methods, and `scheduled!` with `no_retry!`. Unannotated, it must compile.
import pf.Worker
import pf.Response

fetch! = |req| {
	m = req.method()
	Ok(Response.from_text(200, "${Str.inspect(m)} ${req.url()} ${req.segments().len().to_str()}"))
}

scheduled! = |s| {
	s.no_retry!()
	if s.cron() == "" Err(NoCron) else Ok({})
}

queue! = |batch| if batch.messages().len() == 0 Err(Empty) else Ok({})

worker = Worker.new({ fetch!: fetch!, scheduled!: scheduled!, queue!: queue! })

event! = |e| worker.event!(e)
