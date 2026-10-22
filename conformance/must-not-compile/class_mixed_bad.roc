app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: the `rpc` list of `Object.class` has `Room` and `Ledger` methods. One class has one interface.
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

open! = |_self, {}| Ok(1)

settle! = |_self, {}| Ok(2)

room_class = Object.class("Room", { rpc: [open.on(open!), settle.on(settle!)] })

rooms : Object.Namespace(Room)
rooms = Object.namespace("ROOMS", { class: room_class })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch!, objects: [room_class.erase()], bindings: [rooms.declare()] })

event! = |e| worker.event!(e)
