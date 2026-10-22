app [event!] { pf: platform "../../../platform/main.roc" }

## Check: a handler whose `err` is `Infra(Faults)` (an app alias, 2 tags) and that calls another method with `Rpc.forward`.
## Run from the repo root: roc check research/g1a-size/forward-alias/app.roc
## Result: 1 type mismatch at `Rpc.forward` (it needs `Infra(Rpc.Infra)`). ok.roc (the same with `Infra(Rpc.Infra)`) has 0 errors.
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Object
import pf.Io

Faults : [StorageErr(Io.Thrown), RpcErr(Io.Thrown), BadData(Str)]
Err1 : [NotOpen, Infra(Faults)]

inner : Rpc({}, I64, Err1)
inner = Rpc.method("inner")

ns = Object.namespace_named("STORES", "Store")

relay! : Object.Self, {} => Try(I64, Err1)
relay! = |_self, arg| {
	v = ns.named("r").call!(inner, arg) ? Rpc.forward(|e| e)
	Ok(v)
}

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
