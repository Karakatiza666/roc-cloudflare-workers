app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `rooms` is a namespace of the interface `Room`, and `settle` is a method of `Ledger`.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Object
import pf.Rpc
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

room_class : Object.Class(Room)
room_class = Object.class("Room", {})

rooms : Object.Namespace(Room)
rooms = Object.namespace("ROOMS", { class: room_class })

fetch! = |_req| {
	_ = rooms.named("a").call!(settle, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
