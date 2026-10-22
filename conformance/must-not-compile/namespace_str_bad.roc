app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: the class of `Object.namespace` is the value of `Object.class`, not its name as a Str.
import pf.Worker
import pf.Object
import pf.Response

NoRpc := []

rooms : Object.Namespace(NoRpc)
rooms = Object.namespace("ROOMS", { class: "LotRoom" })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
