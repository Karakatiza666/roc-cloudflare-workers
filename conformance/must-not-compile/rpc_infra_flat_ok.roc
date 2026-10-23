app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control of `rpc_infra_flat_bad.roc` (N5 G1a): the `err` of the method has `Infra(Rpc.Infra)`, so the handler that `?`s a storage
## error compiles. `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Rpc
import pf.Object
import pf.Response

Room := []

room_iface : Rpc.Iface(Room)
room_iface = Rpc.iface("Room")

close_out : Rpc(Room, {}, U64, [NotOpen, Infra(Rpc.Infra)])
close_out = room_iface.method("close_out")

close_out! = |self, {}| {
	self.delete_all!()?
	Ok(1)
}

room = Object.class("Room", { rpc: [close_out.on(close_out!)] })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
