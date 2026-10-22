app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of namespace_str_bad.roc: the class is a value of `Object.class`, so it compiles.
import pf.Worker
import pf.Object
import pf.Response

NoRpc := []

room : Object.Class(NoRpc)
room = Object.class("LotRoom", {})

rooms : Object.Namespace(NoRpc)
rooms = Object.namespace("ROOMS", { class: room })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
