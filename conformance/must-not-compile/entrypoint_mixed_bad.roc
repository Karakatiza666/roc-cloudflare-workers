app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: the `rpc` list of `Rpc.entrypoint` has `Room` and `Ledger` methods. An entry point has one interface.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
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

open! = |{}| Ok(1)

settle! = |{}| Ok(2)

fetch! = |_req| Ok(Response.from_text(200, "x"))

admin = Rpc.entrypoint("Admin", { rpc: [open.on_worker(open!), settle.on_worker(settle!)] })

worker = Worker.new({ fetch!: fetch!, entrypoints: [admin] })

event! = |e| worker.event!(e)
