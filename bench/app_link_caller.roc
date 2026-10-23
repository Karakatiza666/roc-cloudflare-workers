app [event!] { pf: platform "platform/main.roc" }

## A fixture of bench/iface-test.mjs and bench/sync-cross-test.mjs (built by bench/build.sh). The caller Worker of a link
## across Workers: the service bindings LEDGER and ADMIN (the interfaces Ledger and AdminApi), and the namespace ROOMS of the
## class Room of another Worker (RoomApi). It has no class and no Rpc method. The Wrangler config says which Worker and which
## entry point or class each binding goes to.
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Service
import pf.Object

Ledger := []
AdminApi := []
RoomApi := []

ledger : Service(Ledger)
ledger = Service.binding("LEDGER", Rpc.iface("Ledger"))

admin : Service(AdminApi)
admin = Service.binding("ADMIN", Rpc.iface("AdminApi"))

rooms : Object.Namespace(RoomApi)
rooms = Object.namespace_remote("ROOMS", { class: "Room", script: "callee" }, Rpc.iface("RoomApi"))

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "caller"))

worker = Worker.new({
	fetch!: fetch!,
	bindings: [ledger.declare(), admin.declare(), rooms.declare()],
})

event! = |e| worker.event!(e)
