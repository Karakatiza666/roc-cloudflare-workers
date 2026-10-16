app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control: it compiles (MODULES.md 10, PLAN.md 8c): a `Secret` in typed data (a CBOR encode).
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Request
import pf.Response
import pf.Secret
import Cbor

fetch! : Request => Try(Response, [])
fetch! = |_req| {
	s = Secret.from_str("hunter2")
	_ = Cbor.encode({ user: "a", token: s.reveal() })
	Ok(Response.from_status(204))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
