app [event!] { pf: platform "platform/main.roc" }

## A fixture of bench/iface-test.mjs and bench/sync-cross-test.mjs (built by bench/build.sh). The callee Worker of a
## link across Workers: the default export serves the interface Ledger, the entry point Admin serves AdminApi, the class
## Room serves RoomApi, and the class Plain has no Rpc method. bench/app_link_callee_b.roc is this file with each
## interface name changed (sed in bench/build.sh).
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Object

Ledger := []
AdminApi := []
RoomApi := []
NoRpc := []

ledger_iface : Rpc.Iface(Ledger)
ledger_iface = Rpc.iface("Ledger")

admin_iface : Rpc.Iface(AdminApi)
admin_iface = Rpc.iface("AdminApi")

room_iface : Rpc.Iface(RoomApi)
room_iface = Rpc.iface("RoomApi")

balance : Rpc(Ledger, {}, {}, Rpc.NoErr)
balance = ledger_iface.method("balance")

purge : Rpc(AdminApi, {}, {}, Rpc.NoErr)
purge = admin_iface.method("purge")

enter : Rpc(RoomApi, {}, {}, Rpc.NoErr)
enter = room_iface.method("enter")

room : Object.Class(RoomApi)
room = Object.class("Room", { rpc: [enter.on(|_, _| Ok({}))] })

plain : Object.Class(NoRpc)
plain = Object.class("Plain", {})

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "callee"))

worker = Worker.new({
	fetch!: fetch!,
	rpc: [balance.on_worker(|_| Ok({}))],
	entrypoints: [Rpc.entrypoint("Admin", { rpc: [purge.on_worker(|_| Ok({}))] })],
	objects: [room.erase(), plain.erase()],
})

event! = |e| worker.event!(e)
