app [event!] { pf: platform "../../platform/main.roc" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object

room = Object.class("Room", { fetch!: |_self, _req| Ok(Response.from_text(200, "hi")) })
rooms = Object.namespace("ROOMS", { class: room })

fetch! : Request => Try(Response, _)
fetch! = |req| Ok(rooms.named("a").fetch!(req)?)

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
