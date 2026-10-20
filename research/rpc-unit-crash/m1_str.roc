app [event!] { pf: platform "../../platform/main.roc" }

## Smallest trigger: a `call!` of an `Rpc` with a `{}` answer, in a `fetch!`.
import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

open : Rpc(Str, Str, [AlreadyOpen])
open = Rpc.method("open")

rooms = Object.namespace("ROOM", { class: "Room" })

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	_ = rooms.named("x").call!(open, "lot")?
	Ok(Response.from_text(200, "ok"))
}

worker = Worker.new({ fetch!: fetch!, bindings: [rooms.declare()] })

event! = |e| worker.event!(e)
