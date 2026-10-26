app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket

NoRpc := []

Member : { name : Str }

slot : Object.Attachment(Member)
slot = Object.attachment("member")

room : Object.Class(NoRpc)
room = Object.class("Room", {
	fetch!: |self, req| {
		{ socket, response } = self.accept!(req)?
		name = req.query("name") ?? "anon"
		slot.set!(socket, { name })?
		Ok(response)
	},
	web_socket_message!: |self, from, msg| {
		for peer in self.sockets!() {
			if peer != from {
				peer.send!(msg)
			}
		}
		Ok({})
	},
})

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(200))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
