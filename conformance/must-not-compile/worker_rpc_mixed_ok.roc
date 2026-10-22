app [event!] { pf: platform "../../bench/platform/main.roc" }

## Control of worker_rpc_mixed_bad.roc: the list has methods of `Room` only. It compiles.
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

worker = Worker.new({ fetch!: fetch!, rpc: [open.on_worker(open!), open.on_worker(open!)] })

event! = |e| worker.event!(e)
