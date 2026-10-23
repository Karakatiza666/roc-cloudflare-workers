app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of class_serves_call_bad.roc: the call of `settle`, the method that the class serves. It compiles.
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

settle! = |_self, {}| Ok(2)

ledger_class = Object.class("Ledger", { rpc: [settle.on(settle!)] })

ledgers = Object.namespace("LEDGERS", { class: ledger_class })

fetch! = |_req| {
	_ = ledgers.named("a").call!(settle, {})
	Ok(Response.from_text(200, "x"))
}

worker = Worker.new({ fetch!: fetch!, objects: [ledger_class.erase()] })

event! = |e| worker.event!(e)
