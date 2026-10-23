app [event!] { pf: platform "../../bench/platform/main.roc" }

## Must not compile (PLAN.md 8h item 2): an Rpc handler that gives `Busy`, a tag that is not in the `err` `[StillOpen]` of its method.
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

close_out! = |{}, {}| Err(Busy)

worker = Worker.new({ fetch!: fetch!, rpc: [close_out.on(close_out!)] })

event! = |e| worker.event!(e)
