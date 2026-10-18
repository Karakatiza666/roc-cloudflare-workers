app [event!] { pf: platform "../../platform/main.roc" }

## Issue 7: a method that `Request` does not have, in an unannotated `fetch!`. The error must be at the call.
import pf.Worker
import pf.Response

fetch! = |req| Ok(Response.from_text(200, req.path()))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
