app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Object
import pf.Sql

NoRpc := []

room : Object.Class(NoRpc)
room = Object.class("Room", {
	init!: |self| {
		_ = self.sql_run!("create table if not exists t (a)", Sql.none)?
		Ok({})
	},
	fetch!: |_self, _req| Ok(Response.from_text(200, "hi")),
})

fetch! : Request => Try(Response, [])
fetch! = |_req| Ok(Response.from_text(200, "hi"))

worker = Worker.new({ fetch!: fetch!, objects: [room.erase()] })

event! = |e| worker.event!(e)
