app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Sql

NoRpc := []

room : Object.Class(NoRpc)
room = Object.class("Room", {
	fetch!: |self, _req| {
		rows = self.sql!("select name from users", Sql.none)?
		Ok(Response.from_text(200, rows.len().to_str()))
	},
})

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_text(200, "hi"))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
