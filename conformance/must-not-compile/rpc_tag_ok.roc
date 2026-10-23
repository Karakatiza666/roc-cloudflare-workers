app [event!] { pf: platform "../../bench/platform/main.roc" }

## The control: the same file with the tag `StillOpen` of the `err`. It compiles.
## `conformance/must-not-compile.sh` runs `roc check` on it.
import pf.Worker
import pf.Rpc
import pf.Response

Room := []

room_iface : Rpc.Iface(Room)
room_iface = Rpc.iface("Room")

close_out : Rpc(Room, {}, U64, [StillOpen])
close_out = room_iface.method("close_out")

fetch! = |_req| Ok(Response.from_text(200, "x"))

close_out! = |{}, {}| Err(StillOpen)

worker = Worker.new({ fetch!: fetch!, rpc: [close_out.on(close_out!)] })

event! = |e| worker.event!(e)
