app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket

Room := []

rooms = Object.namespace("ROOMS", { class: room })

Member : { name : Str }

Said : { text : Str }

member_slot : Object.Attachment(Member)
member_slot = Object.attachment("member")

room : Object.Class(Room)
room = Object.class("Room", {
	fetch!: |self, req| {
		{ socket, response } = self.accept!(req)?
		member_slot.set!(socket, { name: req.query("name") ?? "anon" })?
		self.set_auto_response!({ request: "ping", response: "pong" })?
		Ok(response)
	},
	web_socket_message!: |self, from, msg| {
		member = member_slot.get!(from)?
		said : Said
		said = msg.json()?
		for peer in self.sockets!() {
			if peer != from {
				_ = peer.send_json!({ user: member.name, text: said.text })
			}
		}
		Ok({})
	},
	web_socket_close!: |_self, socket, closed| {
		socket.close!(closed.code, closed.reason)
		Ok({})
	},
})

echo! : Request => Try(Response, _)
echo! = |req| {
	{ socket, response } = WebSocket.accept!(req)?
	loop! = || match socket.receive!() {
		Ok(msg) => {
			_ = socket.send!(msg)
			loop!()
		}
		Err(Closed(_)) => Ok({})
	}
	Ok(response.after(loop!))
}

fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["room", name] =>
		if WebSocket.is_upgrade(req) {
			Ok(rooms.named(name).fetch!(req)?)
		} else {
			Ok(Response.from_status(426))
		}

	["echo"] => echo!(req)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()], bindings: [rooms.declare()] })

event! = |e| worker.event!(e)
