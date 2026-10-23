app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: the Worker serves `settle` (`Ledger`) with `on_worker`, and `ledgers` is a service of `Ledger`, so the call of `open` (a method of `Room`) is a type mismatch.
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

open! = |{}| Ok(1)

settle! = |{}| Ok(2)

ledgers = Service.binding("LEDGERS", ledger_iface)

fetch! = |_req| {
	_ = ledgers.call!(open, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch!, rpc: [settle.on_worker(settle!)] })

event! = |e| worker.event!(e)
