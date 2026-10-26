app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Env
import pf.Log
import pf.Sql

db = D1.binding("DB")

Item : { id : I64 }
fetch! : Request => Try(Response, _)
fetch! = |_req| {
	item : Item
	item = db.first!("SELECT 1 AS id", [])?
	Ok(Response.from_json(200, item))
}

worker = Worker.new({ fetch!: fetch! })

event! = |e| worker.event!(e)
