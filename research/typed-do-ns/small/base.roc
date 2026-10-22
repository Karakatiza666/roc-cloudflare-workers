app [event!] { pf: platform "../../../platform/main.roc" }

## A small app for the wasm size: one class with two Rpc methods, and a fetch that calls one. Today's platform.
import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc

get : Rpc({}, U64, Rpc.NoErr)
get = Rpc.method("get")

add : Rpc(U64, U64, Rpc.NoErr)
add = Rpc.method("add")

get! : Object.Self, {} => Try(U64, Rpc.NoErr)
get! = |_self, {}| Ok(1)

add! : Object.Self, U64 => Try(U64, Rpc.NoErr)
add! = |_self, n| Ok(n + 1)

counter : Object.Class
counter = Object.class("Counter", { rpc: [get.on(get!), add.on(add!)] })

counters = Object.namespace("COUNTER", { class: counter })

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	n = counters.named("a").call!(add, 2)?
	Ok(Response.from_text(200, n.to_str()))
}

worker = Worker.new({ fetch!, objects: [counter], bindings: [counters.declare()] })

event! = |e| worker.event!(e)
