app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `Service.binding_with` has no interface argument ("too few args").
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Rpc
import pf.Service
import pf.Response

Room := []
Ledger := []

room_iface : Rpc.Iface(Room)
room_iface = Rpc.iface("Room")

ledger_iface : Rpc.Iface(Ledger)
ledger_iface = Rpc.iface("Ledger")

open : Rpc(Room, {}, U64, Rpc.NoErr)
open = room_iface.method("open")

settle : Rpc(Ledger, {}, U64, Rpc.NoErr)
settle = ledger_iface.method("settle")

rooms = Service.binding_with("ROOMS", { entrypoint: "Admin" })

fetch! = |_req| {
	_ = rooms.call!(open, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
