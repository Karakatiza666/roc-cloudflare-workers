app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object

room_fetch! : Object.Self, Request => Try(Response, [])
room_fetch! = |_self, _req| Ok(Response.from_text(200, "ok"))

room = Object.class("Room", {
	fetch!: room_fetch!,
	alarm!: |self, _info| {
		_ = self.sql_run!("delete from t", [])?
		Ok({})
	},
})

fetch! : Request => Try(Response, _)
fetch! = |_req| Ok(Response.from_status(404))

worker = Worker.{ fetch!, objects: [room] }

event! = |e| worker.event!(e)
