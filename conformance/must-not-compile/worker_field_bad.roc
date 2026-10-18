app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (PLAN.md 8h item 1): a field of `Worker.new` with the wrong handler type. `fetch!` takes a `Str`, not a
## `Request`. `conformance/must-not-compile.sh` runs `roc check` on it. Its control is `worker_errs_ok.roc`.
import pf.Worker
import pf.Response

fetch! : Str => Try(Response, [])
fetch! = |_s| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
