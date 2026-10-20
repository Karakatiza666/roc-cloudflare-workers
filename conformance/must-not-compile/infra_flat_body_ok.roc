app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control of `infra_flat_body_bad.roc` (N5 G1a): `Request.json!` has the flat tags, so the closed error compiles.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Request
import pf.Response
import pf.Io

read! : Request => Try({ n : I64 }, [BadData(Str), TooLarge, BodyErr(Io.Thrown)])
read! = |req| req.json!()

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
