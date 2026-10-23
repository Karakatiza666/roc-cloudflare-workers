app [event!] { pf: platform "platform/main.roc" }

## A fixture of bench/iface-test.mjs (built by bench/build.sh): the namespace ROOMS names the class Room of this Worker
## with the interface Wrong, and the class serves RoomApi. The load of the app fails (MODULES.md 3).
import pf.Worker
import pf.Request
import pf.Response
import pf.Rpc
import pf.Object

RoomApi := []
Wrong := []

room_iface : Rpc.Iface(RoomApi)
room_iface = Rpc.iface("RoomApi")

enter : Rpc(RoomApi, {}, {}, Rpc.NoErr)
enter = room_iface.method("enter")

room : Object.Class(RoomApi)
room = Object.class("Room", { rpc: [enter.on(|_, _| Ok({}))] })

rooms : Object.Namespace(Wrong)
rooms = Object.namespace_named("ROOMS", "Room", Rpc.iface("Wrong"))

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_text(200, "ns"))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()], bindings: [rooms.declare()] })

event! = |e| worker.event!(e)
