app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (N5 G1a): `accept_with!` gives `TooLarge` flat (the tags that the app gave are too large: bad input),
## so a wrapper with the closed error `[NotUpgrade, Infra([TooLarge])]` does not fit. The control has the flat tag.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Object
import pf.Request
import pf.Response

join! : Object.Self, Request => Try({ socket : Object.Socket, response : Response }, [NotUpgrade, Infra([TooLarge])])
join! = |self, req| self.accept_with!(req, { tags: ["a"] })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
