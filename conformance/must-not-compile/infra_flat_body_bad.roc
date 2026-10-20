app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (N5 G1a): the body reads of `Request` stay flat (bad input from the caller), so `Request.json!` has `BadData`
## and `TooLarge` outside `Infra`. A wrapper with the closed error `[Infra([BadData(Str), TooLarge, BodyErr(Io.Thrown)])]` does not fit.
## The control has the flat tags. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Request
import pf.Response
import pf.Io

read! : Request => Try({ n : I64 }, [Infra([BadData(Str), TooLarge, BodyErr(Io.Thrown)])])
read! = |req| req.json!()

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
