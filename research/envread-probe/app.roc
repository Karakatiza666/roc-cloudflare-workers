app [event!] { pf: platform "../../bench/platform/main.roc" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Kv

## Probe of the dev-mode check of `bindings` (MODULES.md 3): KV is declared, OTHER is read and not declared.
kv = Kv.text("KV")

other = Kv.text("OTHER")

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	_ = kv.get!("a")
	_ = other.get!("b")
	_ = other.get!("c")
	Ok(Response.from_text(200, "ok"))
}

worker = Worker.new({ fetch!: fetch!, bindings: [kv.declare()] })

event! = |e| worker.event!(e)
