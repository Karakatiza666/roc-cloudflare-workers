app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: `room_class` is a `Object.Class(Room)`, and it serves `settle`, a method of `Ledger`.
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

settle! = |_self, {}| Ok(1)

room_class : Object.Class(Room)
room_class = Object.class("Room", { rpc: [settle.on(settle!)] })

fetch! = |_req| Ok(Response.from_text(200, "x"))

worker = Worker.new({ fetch!: fetch!, objects: [room_class.erase()] })

event! = |e| worker.event!(e)
