app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of typed_call_bad.roc: the same call with `open`, a method of `Room`. It compiles.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Object
import pf.Rpc
import pf.Response

Room := []
Ledger := []

room_iface : Rpc.Iface(Room)
room_iface = Rpc.Iface.{}

ledger_iface : Rpc.Iface(Ledger)
ledger_iface = Rpc.Iface.{}

open : Rpc(Room, {}, U64, Rpc.NoErr)
open = Rpc.method("open")

settle : Rpc(Ledger, {}, U64, Rpc.NoErr)
settle = Rpc.method("settle")

room_class : Object.Class(Room)
room_class = Object.class("Room", {})

rooms : Object.Namespace(Room)
rooms = Object.namespace("ROOMS", { class: room_class })

fetch! = |_req| {
	_ = rooms.named("a").call!(open, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
