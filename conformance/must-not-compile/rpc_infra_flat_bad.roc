app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (N5 G1a, MODULES.md 1 "Nested and flat errors"): the `err` of an Rpc method has the flat infra tag
## `StorageErr(Io.Thrown)`, but `delete_all!` gives it inside `Infra(..)`, so the handler that `?`s it does not fit.
## The control `rpc_infra_flat_ok.roc` has `Infra(Rpc.Infra)`. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Rpc
import pf.Object
import pf.Response
import pf.Io

Room := []

room_iface : Rpc.Iface(Room)
room_iface = Rpc.iface("Room")

close_out : Rpc(Room, {}, U64, [NotOpen, StorageErr(Io.Thrown)])
close_out = room_iface.method("close_out")

close_out! = |self, {}| {
	self.delete_all!()?
	Ok(1)
}

room = Object.class("Room", { rpc: [close_out.on(close_out!)] })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
