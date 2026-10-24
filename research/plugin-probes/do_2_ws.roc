app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket

rooms = Object.namespace("ROOMS")

Member : { name : Str }

room = Object.class("Room", {
	fetch!: |self, req| {
		name = req.query("name") ?? "anon"
		{ socket, response } = self.accept!(req)?
		socket.attach!({ name })?
		Ok(response)
	},
	web_socket_message!: |self, from, msg| {
		member : Member
		member = from.attachment!()?
		text = match msg {
			Text(t) => t
			Bytes(_) => "(bytes)"
		}
		for s in self.sockets!() {
			if s != from {
				_ = s.send!(Text("${member.name}: ${text}"))
			}
		}
		Ok({})
	},
	web_socket_close!: |_self, socket, closed| {
		socket.close!(closed.code, "bye")
		Ok({})
	},
})

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["room", name] => {
		if WebSocket.is_upgrade(req) {
			rooms.named(name).fetch!(req)
		} else {
			Ok(Response.from_status(426))
		}
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch!, objects: [room] }

event! = |e| worker.event!(e)
