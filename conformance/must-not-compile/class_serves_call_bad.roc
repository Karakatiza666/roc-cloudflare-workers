app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile: the class serves `settle` (`Ledger`), so its namespace is one of `Ledger` and the call of `open` (a method of `Room`) is a type mismatch.
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

settle! = |_self, {}| Ok(2)

ledger_class = Object.class("Ledger", { rpc: [settle.on(settle!)] })

ledgers = Object.namespace("LEDGERS", { class: ledger_class })

fetch! = |_req| {
	_ = ledgers.named("a").call!(open, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch!, objects: [ledger_class.erase()] })

event! = |e| worker.event!(e)
