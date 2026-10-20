app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control of `infra_flat_kept_bad.roc` (N5 G1a): `accept_with!` gives `TooLarge` flat, so the closed error `[NotUpgrade, TooLarge]` compiles.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Object
import pf.Request
import pf.Response

join! : Object.Self, Request => Try({ socket : Object.Socket, response : Response }, [NotUpgrade, TooLarge])
join! = |self, req| self.accept_with!(req, { tags: ["a"] })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
