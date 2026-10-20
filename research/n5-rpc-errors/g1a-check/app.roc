app [event!] { pf: platform "../../../platform/main.roc" }

## N5 G1a on the real platform: `Rpc.forward` with `?` in a handler (the same domain, and a mapped domain), and
## `Io.timeout` on a nested error. `roc check` only (research/n5-rpc-errors/README.md, section 9).
import pf.Worker
import pf.Rpc
import pf.Object
import pf.Io
import pf.Kv
import pf.Request
import pf.Response

RoomErr : [NotOpen, StillOpen, Infra(Rpc.Infra)]

LedgerErr : [Busy, Infra(Rpc.Infra)]

close_out : Rpc({}, U64, RoomErr)
close_out = Rpc.method("close_out")

relay : Rpc({}, U64, RoomErr)
relay = Rpc.method("relay")

settle : Rpc({}, U64, LedgerErr)
settle = Rpc.method("settle")

rooms = Object.namespace_remote("ROOM", { class: "Room", script: "other" })

cell : Kv.Cell(U64)
cell = Kv.json("KV").cell("n")

## The same error type: `forward(|e| e)`.
relay! : {} => Try(U64, RoomErr)
relay! = |{}| {
	n = rooms.named("a").call!(close_out, {}) ? Rpc.forward(|e| e)
	m = cell.get_or!(0)?
	Ok(n + m)
}

## Another domain: the domain tags of the callee mapped, its `Infra` kept.
settle! : {} => Try(U64, LedgerErr)
settle! = |{}| {
	n = rooms.named("a").call!(close_out, {}) ? Rpc.forward(
		|e| match e {
			NotOpen | StillOpen => Busy
			Infra(i) => Infra(i)
		},
	)
	m = cell.get_or(0).timeout(100).run!()?
	Ok(n + m)
}

## A caller outside Rpc: one exhaustive match on the shape `Infra(..)`, `Remote(..)`.
status! : {} => U16
status! = |{}| match rooms.named("a").call!(close_out, {}) {
	Ok(_) => 200
	Err(Remote(NotOpen)) | Err(Remote(StillOpen)) => 409
	Err(Remote(Infra(_))) => 503
	Err(Infra(RpcErr(_))) => 502
	Err(Infra(BadData(_))) => 500
}

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_status(status!({})))

worker = Worker.new({
	fetch!,
	rpc: [relay.on_worker(relay!), settle.on_worker(settle!)],
	bindings: [cell.declare(), rooms.declare()],
})

event! = |e| worker.event!(e)
