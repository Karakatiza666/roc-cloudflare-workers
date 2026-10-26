app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

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
